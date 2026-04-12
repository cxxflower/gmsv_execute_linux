# gmsv_execute_linux

[![Release](https://github.com/cxxflower/gmsv_execute_linux/actions/workflows/release.yml/badge.svg)](https://github.com/cxxflower/gmsv_execute_linux/actions/workflows/release.yml)
[![License](https://img.shields.io/github/license/cxxflower/gmsv_execute_linux?color=blue)](LICENSE)
[![Platforms](https://img.shields.io/badge/platform-Linux-lightgrey)]()
[![Arch](https://img.shields.io/badge/arch-32bit%20%7C%2064bit-orange)]()

> **Garry's Mod Lua C-module** for Linux that enables safe, asynchronous command execution from within the game server. Ships statically compiled `git` and `ssh` binaries for self-contained server-side operations.

---

## 📑 Table of Contents

- [Features](#-features)
- [Quick Start](#-quick-start)
- [Console Commands](#-console-commands)
- [Lua API](#-lua-api)
- [Raw C Module API](#-raw-c-module-api)
- [Architecture](#-architecture)
- [Memory Management](#-memory-management)
- [Known Limitations](#-known-limitations)
- [Project Structure](#-project-structure)
- [Notes](#-notes)
- [License](#-license)

---

## ✨ Features

| Feature | Description |
|---------|-------------|
| ⚡ Non-blocking execution | `posix_spawn()` + `select()` — never hangs the server thread |
| 🔄 Async callbacks | Fire automatically when commands complete |
| 📦 Output capture | stdout/stderr with 10 MB per-process cap (prevents OOM) |
| 🛠 Process management | List, kill, status-check, and write to stdin of running processes |
| ⏱ Timeout protection | Per-process timeout — SIGKILL on overrun |
| 🐙 Bundled Git | Full git client with all helpers |
| 🔑 Bundled SSH | OpenSSH client + `ssh-keygen` |
| 🏗 Cross-architecture | Builds for both 32-bit (`linux`) and 64-bit (`linux64`) |
| 🐳 Docker-based build | Reproducible builds without host dependency pollution |
| 📝 Auto-fix permissions | `chmod +x` on every server start — SFTP-friendly |
| 🔄 Auto-detect arch | Picks 64-bit or 32-bit binaries automatically |

---

## 🚀 Quick Start

### Building

```bash
./build.sh       # Both architectures
./build64.sh     # 64-bit only
./build32.sh     # 32-bit only
```

Artifacts appear in `out/`, `out64/`, or `out32/`.

### Installation

**Step 1.** Place the `.dll` in `lua/bin/`:

| Arch | File |
|------|------|
| 64-bit | `gmsv_execute_linux64.dll` |
| 32-bit | `gmsv_execute_linux.dll` |

**Step 2.** Place bundled binaries in the server working directory (next to `garrysmod/`):

```
garrysmod/
git64
git64-libexec/
ssh64
ssh-keygen64
```

> [!NOTE]
> For 32-bit: replace `64` → `32`

> [!TIP]
> **No `chmod` needed!** The addon automatically fixes permissions on every server start — just upload via SFTP and go.

**Step 3.** Copy `addon-server-git/lua/` into `garrysmod/addons/`.

### Requirements

- **Docker** & Docker Compose *(for building)*
- **Garry's Mod Linux Dedicated Server**
- **cmake** *(if building without Docker)*

---

## 💻 Console Commands

Access from server console only (`RCON` / `listen host`):

```
git <subcommand> [args...] [--timeout=N]
```

| Parameter | Description |
|-----------|-------------|
| `<subcommand>` | Any git subcommand: `clone`, `status`, `push`, `pull`, `rebase`, etc. |
| `[args...]` | Arguments passed to git |
| `--timeout=N` | Timeout in seconds (default: 600 = 10 min). Process is killed with SIGKILL on overrun |

**Examples:**

```
git clone https://github.com/foo/bar.git
git clone https://github.com/huge/repo.git --timeout=300
git status --short
git log --oneline -n 20
git commit -m "fix: stuff"
git push origin main
git rebase -i HEAD~3
git stash push -m "wip"
git cherry -v
git bisect start
```

Run `git` without arguments to see usage help.

---

## 📜 Lua API

### Shell Execution (C module wrapper)

```lua
execute.exec("uname -a", function(success, stdout, stderr, code)
    if success then
        print("Kernel:", stdout)
    else
        print("Failed:", stderr, "code:", code)
    end
end)
```

### Git API

```lua
local Git = include("server-git/wrapper-git.lua")

-- Prints stdout/stderr to console
Git.Exec({"status", "--short"}, function(success, stdout, stderr, code)
    -- handle result
end)

-- Silent — no console spam
Git.ExecSilent({"rev-parse", "--short", "HEAD"}, function(success, stdout, stderr, code)
    local commit = stdout and stdout:gsub("%s+", "")
end)

-- With custom timeout
Git.ExecWithTimeout({"clone", "https://github.com/huge/repo.git"}, 300, function(success, stdout, stderr, code)
    print("cloned:", success)
end)

-- Interactive stdin (e.g. git add -p)
local h = Git.ExecInteractive({"add", "-p"}, 60)
timer.Simple(1, function()
    execute.write(h, "y\n")
    execute.write(h, "n\n")
    execute.close_stdin(h)
    execute.cleanup(h)
end)

-- Commit from stdin (no -m needed)
Git.CommitInteractive("fix: my stuff", function(success, stdout, stderr, code)
    print("committed:", success)
end)

-- Configuration
Git.WorkingDir = "/path/to/repo"  -- nil = current directory
Git.LogFile = "git.log"           -- nil = no file logging
```

### API Reference — Git

| Function | Description |
|----------|-------------|
| `Git.Exec(args, callback)` | Run git, prints stdout/stderr. Callback: `(success, stdout, stderr, code)` |
| `Git.ExecSilent(args, callback)` | Run git, no console output. Callback: `(success, stdout, stderr, code)` |
| `Git.ExecWithTimeout(args, timeout, callback)` | Run git with timeout. Auto-cleanup. Callback: `(success, stdout, stderr, code)` |
| `Git.ExecInteractive(args, timeout)` | Run git with open stdin. Returns `handle`. Default timeout: 600s |
| `Git.CommitInteractive(message, callback)` | Commit via stdin (`git commit -F -`). No `-m` needed |
| `Git.GIT_EXEC` | Path to git binary (auto-detected: `./git64` or `./git32`) |
| `Git.GIT_SSH` | Path to ssh binary |
| `Git.GIT_LIBEXEC` | Path to git libexec directory |
| `Git.WorkingDir` | Working directory for git operations (nil = current dir) |
| `Git.LogFile` | Log file path (nil = no logging) |

### Git Hook

Fired after every `git` operation (after `Git.Exec` and `Git.ExecSilent`):

```lua
hook.Add("GitCommandComplete", "MyAddon", function(args, success, out, err, code)
    if args[1] == "pull" and code == 0 then
        -- repo updated — reload files
    end
end)
```

---

## ⚙️ Raw C Module API

For direct usage without the addon wrapper:

```lua
require("execute")

-- With callback — ⚠ requires manual cleanup!
local handle = execute.start("sleep 5 && echo done", function(h, success, stdout, stderr, code)
    print("Done:", stdout)
    execute.cleanup(h)  -- REQUIRED or memory leaks
end)

-- Without callback — auto-cleanup on exit
local handle = execute.start("echo 'fire and forget'")

-- Poll each tick
hook.Add("Think", "my_poll", function()
    execute.poll()
end)

-- Query state
local done, success, stdout, stderr, code = execute.status(handle)

-- Kill
execute.kill(handle)

-- Write to stdin (interactive commands)
execute.write(handle, "y\n")
execute.close_stdin(handle)  -- send EOF

-- Set timeout
execute.set_timeout(handle, 600)  -- SIGKILL after 600 seconds

-- List all processes
local procs = execute.list()

-- Clean up
execute.cleanup(handle)
```

### API Reference — C Module

| Function | Description |
|----------|-------------|
| `execute.start(cmd, [callback])` | Start a command. Returns handle. Callback: `(handle, success, stdout, stderr, code)` |
| `execute.poll()` | Drain output, check exited processes, fire callbacks. Returns completed count |
| `execute.status(handle)` | Returns `done, success, stdout, stderr, exit_code`. `nil` if not found |
| `execute.kill(handle)` | Send `SIGTERM`. Returns `true` if found |
| `execute.list()` | Table of tracked processes: `{cmd, pid, done, uptime}` |
| `execute.cleanup(handle)` | Free memory for a finished process. Returns `true` if cleaned up |
| `execute.write(handle, data)` | Write data to process stdin. Returns `true` if written |
| `execute.close_stdin(handle)` | Close stdin (send EOF). Returns `true` if found |
| `execute.set_timeout(handle, seconds)` | Set timeout. `0` to disable. Returns `true` if found |

---

## 🏗 Architecture

```
┌─────────────────┐      posix_spawn()      ┌───────────┐
│  GMod Server    │ ──────────────────────► │  /bin/sh  │
│  (main loop)    │                         └──────────┘
│                 │◄─────── pipes (O_NONBLOCK) ───┘
│  poll()         │        select() + waitpid()
└─────────────────┘
```

- Commands spawned via `posix_spawn()` with pipe redirection (stdin, stdout, stderr)
- All pipes set to `O_NONBLOCK` — no server thread hangs
- `poll()` uses `select()` for efficient I/O multiplexing
- Processes **without** callback → auto-cleaned by `poll()` on exit
- Processes **with** callback → require explicit `execute.cleanup()`
- Per-process timeout → `SIGKILL` on overrun

---

## 🧠 Memory Management

| Scenario | Auto-cleanup? | What to do |
|----------|:---:|------------|
| `execute.start(cmd)` *(no callback)* | ✅ | Nothing — `poll()` cleans up on exit |
| `execute.start(cmd, callback)` | ❌ | Call `execute.cleanup(handle)` after the callback |
| `execute.exec(cmd, callback)` *(addon wrapper)* | ✅ | Nothing — wrapper handles cleanup |
| `Git.ExecWithTimeout(...)` | ✅ | Auto-cleanup in callback |
| `Git.ExecInteractive(...)` | ❌ | Caller calls `execute.cleanup(handle)` |
| Callback throws an error | ✅ | Module auto-cleans to prevent leak |

> [!TIP]
> Use `execute.exec()` from the addon wrapper — it wraps `start()` + `cleanup()` in one call. No manual memory management needed.

---

## ⚠️ Known Limitations

### Interactive commands requiring TTY

Commands that require a terminal (pseudo-TTY) will **not work** through pipe-based stdin:

| Command | Why it fails | Workaround |
|---------|-------------|------------|
| `git commit` (without `-m` or `-F -`) | Opens `$EDITOR` (vim/nano) | Use `Git.CommitInteractive(msg)` |
| `git rebase -i` | Opens editor for rebase todo | Use non-interactive rebase flags |
| `git merge` with conflicts | Opens editor for merge message | Resolve manually, then `git merge --continue` |
| `vim`, `nano`, `less`, `more` | Require full TTY with curses | Not supported — use alternative flags |

### Commands that DO work via stdin pipe

| Command | How |
|---------|-----|
| `git add -p` | Write `y\n`, `n\n`, `s\n` etc. via `execute.write()` |
| `git commit -F -` | Use `Git.CommitInteractive(msg)` |
| `cat > file` | Write content via `execute.write()`, then `close_stdin()` |
| `ssh` with key-based auth | Works — no password prompt needed |

### Race condition on startup

The `git` console command and `Git.*` API use `./git64` by default. If only 32-bit binaries exist on the server, the first `git` call in the first ~4 seconds of server startup may fail with `not found`. The addon auto-detects and switches to `git32` automatically — subsequent calls work correctly.

### SSH authentication

The bundled SSH determines home directory from the binary's location (`/proc/self/exe`), so it looks for `~/.ssh` in the server's working directory. Place SSH keys in `server_root/.ssh/`:

```
server_root/
├── .ssh/
│   ├── id_ed25519
│   ├── id_ed25519.pub
│   └── known_hosts
├── ssh32
├── git32
└── garrysmod/
```

Use key-based auth — password prompts require TTY.

---

## 📁 Project Structure

```
├── src/
│   ├── gm_execute.c         # C module (Lua bindings)
│   └── lua_stub.c           # Stub symbols for standalone builds
├── scripts/
│   ├── build_git.sh         # Static git build script
│   └── build_ssh.sh         # Static ssh build script
├── thirdparty/
│   ├── git/                 # git source (submodule)
│   ├── luajit/              # LuaJIT source (submodule)
│   └── openssh-portable/    # OpenSSH source (submodule)
├── addon-server-git/
│   └── lua/
│       ├── autorun/server/
│       │   └── server-git.lua      # Auto-loads module + wrapper + init
│       └── server-git/
│           ├── init-git.lua        # Console: git <subcommand>
│           └── wrapper-git.lua     # Lua API: Git.Exec, Git.ExecSilent, Git.ExecInteractive
├── CMakeLists.txt
├── Dockerfile
├── docker-compose.yml
├── build.sh / build32.sh / build64.sh
└── README.md
```

---

## 📝 Notes

- Module uses `luaL_register()` for Lua 5.1 / LuaJIT 2.x compatibility (GMod's Lua version)
- `gmod13_open` / `gmod13_close` are the GMod module entry points
- Output capped at **10 MB per process** to prevent OOM from runaway commands
- On shutdown: three-phase cleanup (`SIGTERM` → reap → `SIGKILL`) — no orphaned processes
- `lua_shared.so` dummy library provides stub symbols for standalone linking; GMod's real `lua_shared.so` overrides at runtime
- Default timeout for `ExecInteractive` is **600 seconds** (10 minutes) — enough for large clones
- Timeout fires `SIGKILL` — process is forcefully terminated, no graceful shutdown

---

## 📄 License

See individual source files for licensing. This project links against and bundles:

| Library | License |
|---------|---------|
| [LuaJIT](https://luajit.org/) | MIT |
| [Git](https://github.com/git/git) | GPL-2.0 |
| [OpenSSH](https://github.com/openssh/openssh-portable) | BSD |
