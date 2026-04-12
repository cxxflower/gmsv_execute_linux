-- ============================================================================
-- init-git.lua — Console commands for git
--
-- Единственная команда:  git <anything>
--
--   git clone https://github.com/foo/bar.git
--   git rebase -i HEAD~3
--   git stash push -m "wip"
--   git cherry -v
--   git bisect start
--   git status --short
--   git log --oneline -n 20
--   git push origin main
--   git commit -m "fix: stuff"
--   ...и вообще любая команда git
-- ============================================================================

local Git = _G.Git  -- глобальная, создана в wrapper-git.lua
if not Git then error("[server-git] wrapper-git.lua not loaded!") end

-- ---------------------------------------------------------------------------
-- Access control
-- ---------------------------------------------------------------------------

local function CheckAccess(ply)
    if IsValid(ply) then
        print("[git] access denied — server console only")
        return false
    end
    return true
end

-- ---------------------------------------------------------------------------
-- git <subcommand> [args...]
-- ---------------------------------------------------------------------------

concommand.Add("git", function(ply, cmd, args)
    if not CheckAccess(ply) then return end

    if #args == 0 then
        print("Usage: git <subcommand> [args...] [--timeout=N]")
        print("")
        print("Любая команда git работает напрямую:")
        print('  git clone https://github.com/foo/bar.git')
        print("  git status --short")
        print("  git log --oneline -n 20")
        print("  git commit -m \"fix: stuff\"")
        print("  git push origin main")
        print("  git rebase -i HEAD~3")
        print("  git stash push -m \"wip\"")
        print("  git cherry -v")
        print("  git bisect start")
        print("")
        print("Таймаут (по умолч. 600с = 10мин):")
        print("  git clone https://... --timeout=120")
        print("  git clone https://... --timeout 120")
        return
    end

    -- Парсим --timeout=N или --timeout N из аргументов
    local timeout = 600
    local cleanArgs = {}
    local skipNext = false
    for i, arg in ipairs(args) do
        if skip_next then
            skip_next = false
            -- this arg is the value after --timeout, consume it as timeout value
            local t = tonumber(arg)
            if t then timeout = t end
        else
            local t = arg:match("^%-%-timeout=(%d+)$")
            if t then
                timeout = tonumber(t)
            else
                table.insert(cleanArgs, arg)
            end
        end
        -- If current arg is exactly "--timeout", next arg is the value
        if arg == "--timeout" then
            skip_next = true
            -- Remove the "--timeout" from cleanArgs (it was just added)
            cleanArgs[#cleanArgs] = nil
        end
    end

    if #cleanArgs == 0 then
        print("[git] no command specified")
        return
    end

    -- Запускаем с таймаутом
    Git.ExecWithTimeout(cleanArgs, timeout, function(success, stdout, stderr, code)
        if stdout and stdout ~= "" then
            print("[git] stdout:\n" .. stdout)
        end
        if stderr and stderr ~= "" then
            print("[git] stderr:\n" .. stderr)
        end
        print("[git] exit code: " .. code .. (code == 0 and " (success)" or " (failed)"))
    end)
end)
