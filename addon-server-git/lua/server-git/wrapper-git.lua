-- ============================================================================
-- wrapper-git.lua — минимальный Git API
--
-- Принцип: git — самодостаточный CLI, не нужно оборачивать каждую команду.
--
-- Lua API:
--   Git.Exec(args, callback)           — выполнить git, печатает вывод в консоль
--   Git.ExecSilent(args, callback)     — выполнить git, НЕ печатает вывод
--
-- Конфигурация:
--   Git.WorkingDir = "/path/to/repo"   — рабочая директория (по умолч. текущая)
--
-- Console:
--   git <subcommand> [args...]         — прямой проброс в git
-- ============================================================================

local Git = {}
_G.Git = Git  -- делаем глобальной для init-git.lua

-- ---------------------------------------------------------------------------
-- Configuration (exposed for startup validation)
-- ---------------------------------------------------------------------------
Git.GIT_EXEC    = "./git64"
Git.GIT_SSH     = "./ssh64"
Git.GIT_LIBEXEC = "./git64-libexec"

Git.WorkingDir = nil  -- nil = текущая директория; задать абсолютный путь при необходимости
Git.LogFile = nil     -- nil = без логирования; "data/git.log" = писать в файл

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

--- Экранировать аргумент для sh (оборачивает в кавычки, экранирует спецсимволы)
local function shQuote(s)
    s = tostring(s)
    if s == "" then return "''" end
    -- Если аргумент безопасный — можно без кавычек
    if s:match("^[%w._/=%-]+$") then return s end
    -- Одинарные кавычки экранируют всё, включая $ ` " ! \ и т.д.
    -- Единственное, что нужно экранировать — саму одинарную кавычку
    return "'" .. s:gsub("'", "'\\''") .. "'"
end

--- Собрать shell-команду из таблицы аргументов git
-- Читает Git.GIT_* напрямую — чтобы server-git.lua мог менять их в рантайме
local function buildGitCmd(args)
    local parts = {}
    if Git.WorkingDir and Git.WorkingDir ~= "" then
        table.insert(parts, "cd " .. shQuote(Git.WorkingDir) .. " &&")
    end
    table.insert(parts, "GIT_SSH=" .. shQuote(Git.GIT_SSH))
    table.insert(parts, shQuote(Git.GIT_EXEC))
    table.insert(parts, "--exec-path=" .. shQuote(Git.GIT_LIBEXEC))
    for _, arg in ipairs(args) do
        table.insert(parts, shQuote(arg))
    end
    return table.concat(parts, " ")
end

--- Базовое выполнение git команды
local function doExec(args, callback, printOutput)
    if type(args) ~= "table" or #args == 0 then
        error("Git.Exec / Git.ExecSilent: args must be a non-empty table, e.g. {\"status\"}")
    end

    local cmd = buildGitCmd(args)
    execute.exec(cmd, function(success, stdout, stderr, code)
        if printOutput then
            if stdout and stdout ~= "" then
                print("[git] stdout:\n" .. stdout)
            end
            if stderr and stderr ~= "" then
                print("[git] stderr:\n" .. stderr)
            end
        end
        -- GMOD hook — позволяет другим аддонам реагировать на git-операции
        -- pcall чтобы ошибка в чужом хуке не убила callback и остальные хуки
        local ok, err = pcall(hook.Run, "GitCommandComplete", args, success, stdout, stderr, code)
        if not ok then
            print("[git] hook error: " .. tostring(err))
        end

        -- Логирование в файл если включено
        if Git.LogFile and Git.LogFile ~= "" then
            local ts = os.date("%Y-%m-%d %H:%M:%S")
            local entry = string.format(
                "[%s] git %s → code %d\n",
                ts,
                table.concat(args, " "),
                code
            )
            if stdout and stdout ~= "" then
                entry = entry .. "  stdout:\n" .. stdout:gsub("\n", "\n  ") .. "\n"
            end
            if stderr and stderr ~= "" then
                entry = entry .. "  stderr:\n" .. stderr:gsub("\n", "\n  ") .. "\n"
            end
            entry = entry .. "\n"
            file.Append(Git.LogFile, entry)
        end

        if callback then
            callback(success, stdout, stderr, code)
        end
    end)
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Выполнить git команду с таймаутом.
-- @param args table
-- @param timeout number — таймаут в секундах (0 = без таймаута)
-- @param callback function|nil — callback(success, stdout, stderr, code)
function Git.ExecWithTimeout(args, timeout, callback)
    if type(args) ~= "table" or #args == 0 then
        error("Git.ExecWithTimeout: args must be a non-empty table")
    end
    local cmd = buildGitCmd(args)
    local h = execute.start(cmd, function(handle, success, stdout, stderr, code)
        if callback then callback(success, stdout, stderr, code) end
        execute.cleanup(handle)
    end)
    execute.set_timeout(h, timeout)
    return h
end

--- Выполнить git команду (async). Печатает stdout/stderr в консоль.
-- @param args     table  – {"status", "--short"} или {"commit", "-m", "fix: my stuff"}
-- @param callback function|nil – callback(success, stdout, stderr, code)
function Git.Exec(args, callback)
    doExec(args, callback, true)
end

--- Выполнить git команду (async). НЕ печатает вывод — для программного использования.
-- @param args     table
-- @param callback function|nil – callback(success, stdout, stderr, code)
function Git.ExecSilent(args, callback)
    doExec(args, callback, false)
end

--- Выполнить git команду с интерактивным stdin.
-- Возвращает handle для execute.write() и execute.close_stdin()
-- ВАЖНО: вызывающий сам вызывает execute.poll() и execute.cleanup(handle)
-- Автоматически устанавливает таймаут 10 минут (600с).
-- Для отключения таймаута передать timeout=0.
--
-- Пример: git add -p с автоматическим "yes"
--   local h = Git.ExecInteractive({"add", "-p"})
--   timer.Simple(1, function()
--       execute.write(h, "y\n")  -- returns bytes written (0 on EAGAIN — retry)
--       execute.close_stdin(h)
--       execute.cleanup(h)
--   end)
--
-- @param args table
-- @param timeout number|nil — таймаут в секундах (по умолч. 600)
-- @return handle (integer)
function Git.ExecInteractive(args, timeout)
    if type(args) ~= "table" or #args == 0 then
        error("Git.ExecInteractive: args must be a non-empty table")
    end
    local cmd = buildGitCmd(args)
    local h = execute.start(cmd)
    execute.set_timeout(h, timeout == 0 and 0 or (timeout or 600))
    return h
end

--- Коммит из stdin (git commit -F -). Не требует -m.
-- Читает сообщение из stdin — неблокирующе, через pipe.
-- @param message string — текст коммита
-- @param callback function|nil — callback(success, stdout, stderr, code)
function Git.CommitInteractive(message, callback)
    local h = execute.start(buildGitCmd({"commit", "-F", "-"}), function() end)
    execute.set_timeout(h, 600)
    execute.poll()

    local watchName = "git_commit_" .. h
    local msg = message .. "\n"
    local offset = 0

    timer.Create(watchName, 0.1, 0, function()
        local status = {execute.status(h)}
        if status[1] == nil then
            timer.Remove(watchName)
            execute.cleanup(h)
            return
        end

        local done, success, stdout, stderr, code = status[1], status[2], status[3], status[4], status[5]

        -- Write message incrementally, retrying on EAGAIN (0 bytes written)
        if offset < #msg then
            local remaining = msg:sub(offset + 1)
            local bytes_written = execute.write(h, remaining)
            if bytes_written < 0 then
                -- Permanent error (EPIPE/EBADF) — stdin is closed, stop retrying
                offset = #msg  -- mark as "done writing" to avoid further attempts
            elseif bytes_written > 0 then
                offset = offset + bytes_written
            end
            execute.poll()

            -- All data written — close stdin to signal EOF
            if offset >= #msg then
                execute.close_stdin(h)
            end
        end

        if done then
            timer.Remove(watchName)
            execute.cleanup(h)
            if callback then callback(success, stdout, stderr, code) end
        end
    end)
end

-- ============================================================================
return Git
