-- ============================================================================
-- execute_wrapper.lua — удобная обёртка над модулем gmsv_execute_linux
--
-- Загрузка:
--   include("execute_wrapper.lua")
--   -- или в lua/autorun/server/ sv_execute_wrapper.lua
--
-- Использование:
--   execute.exec("ls -la", function(success, stdout, stderr, code)
--       print("stdout:", stdout)
--   end)
--
-- poll() вызывается автоматически каждый тик (Think hook).
-- cleanup() вызывается автоматически после завершения команды.
-- Память не утекает.
-- ============================================================================
-- Защита от двойной инициализации
-- Загружаем C-модуль
require("execute")
-- Убедиться, что модуль загрузился
if not execute then error("gmsv_execute_linux module not loaded! Make sure gmsv_execute_linux64.dll is in lua/bin/") end

-- ---------------------------------------------------------------------------
-- execute.exec(cmd, callback)
-- callback: function(success, stdout, stderr, exit_code)
-- ---------------------------------------------------------------------------
function execute.exec(cmd, callback)
    local h = execute.start(cmd, function(handle, success, stdout, stderr, code)
        if callback then callback(success, stdout, stderr, code) end
        execute.cleanup(handle) -- всегда, даже если callback упал
    end)
    return h
end

-- ---------------------------------------------------------------------------
-- Автоматический poll каждый тик
-- ---------------------------------------------------------------------------
hook.Add("Think", "execute_autopoll", function() execute.poll() end)
-- ---------------------------------------------------------------------------
-- Очистка при выгрузке (shutdown)
-- ---------------------------------------------------------------------------
hook.Add("ShutDown", "execute_wrapper_shutdown", function() hook.Remove("Think", "execute_autopoll") end)

-- wrapper-git.lua должен загрузиться ПЕРЕД init-git.lua (init использует Git)
include("server-git/wrapper-git.lua")

-- ---------------------------------------------------------------------------
-- Конфиг (редактировать lua/server-git/server-git-config.lua)
-- ---------------------------------------------------------------------------
include("server-git/server-git-config.lua")

local ARCH = ServerGitConfig.ARCH or "64"

local function initGit()
    local bins = {
        git     = "./git" .. ARCH,
        ssh     = "./ssh" .. ARCH,
        libexec = "./git" .. ARCH .. "-libexec/git-core",
    }

    Git.GIT_EXEC    = bins.git
    Git.GIT_SSH     = bins.ssh
    Git.GIT_LIBEXEC = bins.libexec

    print("[server-git] Using " .. ARCH .. "-bit binaries: " .. bins.git)

    -- Проверяем что бинарник существует (GMod file API)
    -- file.Exists работает относительно garrysmod/
    -- Бинарники лежат в корне сервера (рядом с garrysmod/), поэтому проверяем через execute.start
    local checkHandle = execute.start("test -f " .. bins.git, function(_, success)
        if not success then
            error(
                "[server-git] " .. bins.git .. " not found!\n" ..
                "Place git" .. ARCH .. ", ssh" .. ARCH .. ", and git" .. ARCH .. "-libexec in the server working directory (next to garrysmod/)."
            )
        end

        -- Фиксим permissions
        print("[server-git] Fixing binary permissions...")
        local permHandles = {}
        local permDone = {}

        for _, bin in ipairs({ bins.git, bins.ssh }) do
            local h = execute.start("test -x " .. bin .. " || chmod +x " .. bin)
            table.insert(permHandles, h)
            permDone[h] = false
        end
        local h3 = execute.start("find " .. bins.libexec .. " -type f ! -perm -111 -exec chmod +x {} + 2>/dev/null || true")
        table.insert(permHandles, h3)
        permDone[h3] = false

        local function pollPerms()
            execute.poll()
            local allDone = true
            for _, h in ipairs(permHandles) do
                if not permDone[h] then
                    local st = {execute.status(h)}
                    if st[1] == nil or st[1] then
                        permDone[h] = true
                    else
                        allDone = false
                    end
                end
            end
            if not allDone then
                timer.Simple(0.1, pollPerms)
            else
                print("[server-git] Ready!")
                include("server-git/init-git.lua")
            end
        end
        pollPerms()
    end)
    -- poll запустит callback через Think hook
end

initGit()
