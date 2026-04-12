#define _POSIX_C_SOURCE 200809L

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <sys/wait.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <sys/select.h>
#include <spawn.h>
#include <time.h>

extern char **environ;

#include "lauxlib.h"
#include "lua.h"
#include "lualib.h"

// Max captured output per process (prevent OOM from runaway commands)
#define DRAIN_MAX_BYTES (10 * 1024 * 1024)  // 10 MB

// ============================================================================
// Dynamic buffer
// ============================================================================
typedef struct {
    char *data;
    size_t len;
    size_t cap;
} dynbuf_t;

static void dynbuf_init(dynbuf_t *db) {
    db->data = NULL;
    db->len = 0;
    db->cap = 0;
}

static int dynbuf_append(dynbuf_t *db, const char *buf, size_t len) {
    if (len == 0) return 0;
    // Overflow check: ensure db->len + len + 1 won't wrap
    if (len > SIZE_MAX - db->len - 1) return -1;
    size_t needed = db->len + len + 1;
    if (needed > db->cap) {
        // Overflow check on doubling
        if (needed > SIZE_MAX / 2) return -1;
        db->cap = needed * 2;
        char *tmp = realloc(db->data, db->cap);
        if (!tmp) return -1;
        db->data = tmp;
    }
    memcpy(db->data + db->len, buf, len);
    db->len += len;
    return 0;
}

static void dynbuf_free(dynbuf_t *db) {
    free(db->data);
}

static void dynbuf_push(lua_State *L, dynbuf_t *db) {
    if (db->data && db->len > 0) {
        lua_pushlstring(L, db->data, db->len);
    } else {
        lua_pushstring(L, "");
    }
}

static int drain_fd_nonblock(int fd, dynbuf_t *db) {
    char buf[4096];
    ssize_t n;
    while ((n = read(fd, buf, sizeof(buf))) > 0) {
        if (dynbuf_append(db, buf, (size_t)n) < 0) return -1;
        // Cap buffer to prevent OOM from runaway processes
        if (db->len >= DRAIN_MAX_BYTES) {
            db->len = DRAIN_MAX_BYTES;
            close(fd);
            return 1;  // signal caller: cap reached, fd closed
        }
    }
    if (n < 0 && errno == EINTR) return 0;  // interrupted — try again on next poll
    if (n == 0) {
        // EOF: child closed this end of pipe
        close(fd);
        return 1;  // signal caller to invalidate fd
    }
    if (n < 0) {
        if (errno == EAGAIN) return 0;  // no data right now
        // EBADF, EPIPE, etc. — pipe is dead
        close(fd);
        return 1;  // signal caller to invalidate fd
    }
    return 0;
}

// ============================================================================
// Process tracker (linked list)
// ============================================================================
typedef struct proc_entry {
    unsigned int handle;
    pid_t pid;
    char *cmd;               // copied command string
    int stdin_fd;            // write end of stdin pipe (-1 if closed)
    int stdout_fd;
    int stderr_fd;
    dynbuf_t out;
    dynbuf_t err;
    int done;
    int exit_code;
    int success;
    time_t start_time;       // when the process was started
    time_t timeout_at;       // kill time (0 = no timeout)
    time_t sigterm_at;       // when SIGTERM was sent (0 = not yet)
    int callback_ref;        // LUA_REFNIL = no callback
    lua_State *L;            // Lua state at creation time (for safe unref/callback)
    struct proc_entry *next;
} proc_entry_t;

static proc_entry_t *g_procs = NULL;
static unsigned int g_next_handle = 1;

static proc_entry_t *proc_find(unsigned int handle) {
    for (proc_entry_t *p = g_procs; p; p = p->next) {
        if (p->handle == handle) return p;
    }
    return NULL;
}

static void proc_remove(unsigned int handle) {
    proc_entry_t **pp = &g_procs;
    while (*pp) {
        if ((*pp)->handle == handle) {
            proc_entry_t *p = *pp;
            *pp = p->next;
            free(p->cmd);
            if (p->stdin_fd >= 0) close(p->stdin_fd);
            if (p->stdout_fd >= 0) close(p->stdout_fd);
            if (p->stderr_fd >= 0) close(p->stderr_fd);
            dynbuf_free(&p->out);
            dynbuf_free(&p->err);
            if (p->callback_ref != LUA_NOREF && p->callback_ref != LUA_REFNIL) {
                luaL_unref(p->L, LUA_REGISTRYINDEX, p->callback_ref);
            }
            free(p);
            return;
        }
        pp = &(*pp)->next;
    }
}

// ============================================================================
// execute.start(command, [callback]) -> handle
//   callback: function(success, stdout, stderr, exit_code)
//   Non-blocking. Call execute.poll() each tick to process output and trigger callbacks.
// ============================================================================
static int l_execute_start(lua_State *L)
{
    const char *cmd = luaL_checkstring(L, 1);
    int has_callback = lua_isfunction(L, 2);

    int stdin_pipe[2], stdout_pipe[2], stderr_pipe[2];
    if (pipe(stdin_pipe) < 0) {
        return luaL_error(L, "execute.start: stdin pipe() failed: %s", strerror(errno));
    }
    if (pipe(stdout_pipe) < 0) {
        close(stdin_pipe[0]); close(stdin_pipe[1]);
        return luaL_error(L, "execute.start: stdout pipe() failed: %s", strerror(errno));
    }
    if (pipe(stderr_pipe) < 0) {
        close(stdin_pipe[0]); close(stdin_pipe[1]);
        close(stdout_pipe[0]); close(stdout_pipe[1]);
        return luaL_error(L, "execute.start: stderr pipe() failed: %s", strerror(errno));
    }

    // Set read ends non-blocking
    if (fcntl(stdin_pipe[0], F_SETFL, O_NONBLOCK) < 0 ||
        fcntl(stdout_pipe[0], F_SETFL, O_NONBLOCK) < 0 ||
        fcntl(stderr_pipe[0], F_SETFL, O_NONBLOCK) < 0) {
        close(stdin_pipe[0]); close(stdin_pipe[1]);
        close(stdout_pipe[0]); close(stdout_pipe[1]);
        close(stderr_pipe[0]); close(stderr_pipe[1]);
        return luaL_error(L, "execute.start: fcntl() failed: %s", strerror(errno));
    }

    pid_t pid;
    char *shell_argv[] = { "sh", "-c", (char*)cmd, NULL };

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_addclose(&actions, stdin_pipe[1]);
    posix_spawn_file_actions_addclose(&actions, stdout_pipe[0]);
    posix_spawn_file_actions_addclose(&actions, stderr_pipe[0]);
    posix_spawn_file_actions_adddup2(&actions, stdin_pipe[0], STDIN_FILENO);
    posix_spawn_file_actions_adddup2(&actions, stdout_pipe[1], STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&actions, stderr_pipe[1], STDERR_FILENO);
    posix_spawn_file_actions_addclose(&actions, stdin_pipe[0]);
    posix_spawn_file_actions_addclose(&actions, stdout_pipe[1]);
    posix_spawn_file_actions_addclose(&actions, stderr_pipe[1]);

    int ret = posix_spawn(&pid, "/bin/sh", &actions, NULL, shell_argv, environ);
    posix_spawn_file_actions_destroy(&actions);

    if (ret != 0) {
        close(stdin_pipe[0]); close(stdin_pipe[1]);
        close(stdout_pipe[0]); close(stdout_pipe[1]);
        close(stderr_pipe[0]); close(stderr_pipe[1]);
        return luaL_error(L, "execute.start: posix_spawn() failed: %s", strerror(ret));
    }

    // Parent: close read end of stdin, write ends of stdout/stderr
    close(stdin_pipe[0]);
    close(stdout_pipe[1]);
    close(stderr_pipe[1]);

    proc_entry_t *p = calloc(1, sizeof(proc_entry_t));
    if (!p) {
        kill(pid, SIGKILL);
        waitpid(pid, NULL, WNOHANG);
        close(stdin_pipe[1]);
        close(stdout_pipe[0]);
        close(stderr_pipe[0]);
        return luaL_error(L, "execute.start: out of memory");
    }

    // Handle overflow: skip handles that are already in use
    unsigned int start = g_next_handle;
    unsigned int handle;
    do {
        handle = g_next_handle;
        g_next_handle++;
        if (g_next_handle == 0) g_next_handle = 1;  // wrap around, 0 is invalid
    } while (g_next_handle != start && proc_find(handle));

    p->handle = handle;
    p->pid = pid;
    p->cmd = strdup(cmd);
    if (!p->cmd) {
        // strdup failed — still usable, just won't have a command name
        fprintf(stderr, "[execute] handle %d: strdup failed, cmd name unavailable\n", p->handle);
    }
    p->L = L;
    p->stdin_fd = stdin_pipe[1];   // keep write end for execute.write()
    p->stdout_fd = stdout_pipe[0];
    p->stderr_fd = stderr_pipe[0];
    dynbuf_init(&p->out);
    dynbuf_init(&p->err);
    p->done = 0;
    p->start_time = time(NULL);
    p->timeout_at = 0;  // no timeout by default

    if (has_callback) {
        lua_pushvalue(L, 2);
        p->callback_ref = luaL_ref(L, LUA_REGISTRYINDEX);
    } else {
        p->callback_ref = LUA_REFNIL;
    }

    p->next = g_procs;
    g_procs = p;

    lua_pushinteger(L, p->handle);
    return 1;
}

// ============================================================================
// execute.poll() -> number of completed processes this tick
//   Drains output, checks for exited processes, calls callbacks.
//   Safe against list modifications from callbacks: after every callback,
//   the scan restarts from the head of the list.
// ============================================================================
static int l_execute_poll(lua_State *L)
{
    int completed = 0;

    // Iterate by re-scanning from head each time, so that if a callback
    // removes a different entry, our iteration pointer stays valid.
    proc_entry_t *p = g_procs;
    while (p) {
        if (p->done) { p = p->next; continue; }

        unsigned int handle = p->handle;  // save identity for re-find
        int stdout_fd = p->stdout_fd;
        int stderr_fd = p->stderr_fd;

        // If both fds are closed, nothing to select on — skip to exit check
        if (stdout_fd < 0 && stderr_fd < 0) {
            goto check_exit;
        }

        // Safety: fd_set has a fixed size (FD_SETSIZE, typically 1024).
        if ((stdout_fd >= 0 && stdout_fd >= FD_SETSIZE) ||
            (stderr_fd >= 0 && stderr_fd >= FD_SETSIZE)) {
            fprintf(stderr, "[execute] handle %d: fd exceeds FD_SETSIZE (%d), treating as done\n",
                    handle, FD_SETSIZE);
            p->done = 1;
            p->exit_code = -1;
            p->success = 0;
            completed++;
            if (p->stdout_fd >= 0) { close(p->stdout_fd); p->stdout_fd = -1; }
            if (p->stderr_fd >= 0) { close(p->stderr_fd); p->stderr_fd = -1; }
            proc_remove(handle);
            p = g_procs;  // restart — list was modified
            continue;
        }

        int maxfd = 1;
        if (stdout_fd >= 0 && stdout_fd >= maxfd) maxfd = stdout_fd + 1;
        if (stderr_fd >= 0 && stderr_fd >= maxfd) maxfd = stderr_fd + 1;

        fd_set rfds;
        FD_ZERO(&rfds);
        if (stdout_fd >= 0) FD_SET(stdout_fd, &rfds);
        if (stderr_fd >= 0) FD_SET(stderr_fd, &rfds);

        struct timeval tv = {0, 0}; // non-blocking
        int sel = select(maxfd, &rfds, NULL, NULL, &tv);

        if (sel > 0) {
            if (stdout_fd >= 0 && FD_ISSET(stdout_fd, &rfds)) {
                if (drain_fd_nonblock(stdout_fd, &p->out) == 1) {
                    p->stdout_fd = -1;
                }
            }
            if (stderr_fd >= 0 && FD_ISSET(stderr_fd, &rfds)) {
                if (drain_fd_nonblock(stderr_fd, &p->err) == 1) {
                    p->stderr_fd = -1;
                }
            }
        } else if (sel < 0 && errno != EINTR) {
            // select() error — treat as done
            fprintf(stderr, "[execute] select() error for handle %d: %s\n", handle, strerror(errno));
            p->done = 1;
            p->exit_code = -1;
            p->success = 0;
            completed++;
            if (p->stdout_fd >= 0) { close(p->stdout_fd); p->stdout_fd = -1; }
            if (p->stderr_fd >= 0) { close(p->stderr_fd); p->stderr_fd = -1; }
            int has_callback = (p->callback_ref != LUA_NOREF && p->callback_ref != LUA_REFNIL);
            if (!has_callback) {
                proc_remove(handle);
                p = g_procs;
                continue;
            }
            lua_rawgeti(p->L, LUA_REGISTRYINDEX, p->callback_ref);
            lua_pushinteger(p->L, p->handle);
            lua_pushboolean(p->L, 0);
            dynbuf_push(p->L, &p->out);
            dynbuf_push(p->L, &p->err);
            lua_pushinteger(p->L, -1);
            if (lua_pcall(p->L, 5, 0, 0) != LUA_OK) {
                const char *err = lua_tostring(p->L, -1);
                lua_pop(p->L, 1);
                if (err)
                    fprintf(stderr, "[execute] callback error on select failure (handle %d): %s\n",
                            handle, err);
            }
            proc_remove(handle);
            p = g_procs;
            continue;
        }

    check_exit:
        {
        int status = 0;
        // Re-find p (list may have been modified by a callback above,
        // e.g. if select error callback cleaned up another handle)
        p = proc_find(handle);
        if (!p) { p = g_procs; continue; }  // was removed — restart

        if (p->timeout_at > 0 && time(NULL) >= p->timeout_at) {
            fprintf(stderr, "[execute] handle %d timed out, killing\n", p->handle);
            kill(p->pid, SIGKILL);
            waitpid(p->pid, &status, WNOHANG);
            p->done = 1;
            p->exit_code = -1;
            p->success = 0;
            completed++;

            int has_callback = (p->callback_ref != LUA_NOREF && p->callback_ref != LUA_REFNIL);
            if (!has_callback) {
                proc_remove(p->handle);
                p = g_procs;
                continue;
            }
            lua_rawgeti(p->L, LUA_REGISTRYINDEX, p->callback_ref);
            lua_pushinteger(p->L, p->handle);
            lua_pushboolean(p->L, 0);
            dynbuf_push(p->L, &p->out);
            lua_pushstring(p->L, "timed out");
            lua_pushinteger(p->L, p->exit_code);
            if (lua_pcall(p->L, 5, 0, 0) != LUA_OK) {
                const char *err = lua_tostring(p->L, -1);
                lua_pop(p->L, 1);
                if (err)
                    fprintf(stderr, "[execute] callback error on timeout (handle %d): %s\n",
                            handle, err);
            }
            proc_remove(p->handle);
            p = g_procs;
            continue;
        }

        // Re-find p again (timeout callback could have modified the list)
        p = proc_find(handle);
        if (!p) { p = g_procs; continue; }

        // Check exit
        int w = waitpid(p->pid, &status, WNOHANG);
        if (w > 0) {
            // Drain remaining
            if (p->stdout_fd >= 0 && drain_fd_nonblock(p->stdout_fd, &p->out) == 1) {
                p->stdout_fd = -1;
            }
            if (p->stderr_fd >= 0 && drain_fd_nonblock(p->stderr_fd, &p->err) == 1) {
                p->stderr_fd = -1;
            }

            p->done = 1;
            p->exit_code = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
            p->success = WIFEXITED(status) && WEXITSTATUS(status) == 0;
            completed++;

            int has_callback = (p->callback_ref != LUA_NOREF && p->callback_ref != LUA_REFNIL);

            // Auto-cleanup finished processes without a callback
            if (!has_callback) {
                proc_remove(p->handle);
                p = g_procs;
                continue;
            }

            // Call callback
            lua_rawgeti(p->L, LUA_REGISTRYINDEX, p->callback_ref);
            lua_pushinteger(p->L, p->handle);
            lua_pushboolean(p->L, p->success);
            dynbuf_push(p->L, &p->out);
            dynbuf_push(p->L, &p->err);
            lua_pushinteger(p->L, p->exit_code);
            if (lua_pcall(p->L, 5, 0, 0) != LUA_OK) {
                const char *err = lua_tostring(p->L, -1);
                lua_pop(p->L, 1);
                if (err)
                    fprintf(stderr, "[execute] callback error on exit (handle %d): %s\n",
                            handle, err);
            }
            proc_remove(p->handle);
            p = g_procs;
            continue;
        } else if (w < 0 && errno == ECHILD) {
            fprintf(stderr, "[execute] handle %d (pid %d) already reaped (ECHILD), cleaning up\n",
                    p->handle, p->pid);
            p->done = 1;
            p->exit_code = -1;
            p->success = 0;
            completed++;
            proc_remove(p->handle);
            p = g_procs;
            continue;
        }

        // SIGKILL escalation
        if (p->sigterm_at > 0 && !p->done && time(NULL) >= p->sigterm_at + 2) {
            fprintf(stderr, "[execute] handle %d (pid %d) didn't exit after SIGTERM, sending SIGKILL\n",
                    p->handle, p->pid);
            kill(p->pid, SIGKILL);
            p->sigterm_at = 0;
        }
        }  // end check_exit block

        // No callback fired this iteration — advance normally
        p = p->next;
    }

    lua_pushinteger(L, completed);
    return 1;
}

// ============================================================================
// execute.status(handle) -> done, success, stdout, stderr, exit_code
//   Returns nil if handle not found.
// ============================================================================
static int l_execute_status(lua_State *L)
{
    unsigned int handle = (unsigned int)luaL_checkinteger(L, 1);
    proc_entry_t *p = proc_find(handle);
    if (!p) {
        lua_pushnil(L);
        return 1;
    }

    lua_pushboolean(L, p->done);
    lua_pushboolean(L, p->success);
    dynbuf_push(L, &p->out);
    dynbuf_push(L, &p->err);
    lua_pushinteger(L, p->exit_code);
    return 5;
}

// ============================================================================
// execute.kill(handle) -> bool (true if found and signaled)
//   Sends SIGTERM first. On subsequent poll() calls, if the process is still
//   alive after 2 seconds, SIGKILL will be sent automatically.
// ============================================================================
static int l_execute_kill(lua_State *L)
{
    unsigned int handle = (unsigned int)luaL_checkinteger(L, 1);
    proc_entry_t *p = proc_find(handle);
    if (!p) {
        lua_pushboolean(L, 0);
        return 1;
    }

    int ret = kill(p->pid, SIGTERM);
    if (ret < 0) {
        lua_pushboolean(L, 0);
        return 1;
    }
    p->sigterm_at = time(NULL);
    lua_pushboolean(L, 1);
    return 1;
}

// ============================================================================
// execute.list() -> table
//   {
//     [handle] = {
//       cmd     = "ls -la",
//       pid     = 12345,
//       done    = false,
//       uptime  = 3.5  -- seconds since start
//     }
//   }
// ============================================================================
static int l_execute_list(lua_State *L)
{
    lua_newtable(L);

    time_t now = time(NULL);
    proc_entry_t *p = g_procs;
    while (p) {
        long uptime = (long)(now - p->start_time);

        // Push entry table
        lua_newtable(L);

        lua_pushstring(L, p->cmd ? p->cmd : "");
        lua_setfield(L, -2, "cmd");

        lua_pushinteger(L, p->pid);
        lua_setfield(L, -2, "pid");

        lua_pushboolean(L, p->done);
        lua_setfield(L, -2, "done");

        lua_pushinteger(L, uptime);
        lua_setfield(L, -2, "uptime");

        // Set in main table: result[handle] = entry
        lua_pushinteger(L, p->handle);
        lua_insert(L, -2);  // entry below handle
        lua_settable(L, -3);

        p = p->next;
    }

    return 1;
}

// ============================================================================
// execute.cleanup(handle) — remove finished process entry
// ============================================================================
static int l_execute_cleanup(lua_State *L)
{
    unsigned int handle = (unsigned int)luaL_checkinteger(L, 1);
    proc_entry_t *p = proc_find(handle);
    if (!p || !p->done) {
        lua_pushboolean(L, 0);
        return 1;
    }
    proc_remove(handle);
    lua_pushboolean(L, 1);
    return 1;
}

// ============================================================================
// execute.write(handle, data) -> bytes_written
//   > 0 : bytes successfully written
//   = 0 : EAGAIN — pipe full, retry later
//   < 0 : permanent error (EPIPE/EBADF) — stdin is closed
// ============================================================================
static int l_execute_write(lua_State *L)
{
    unsigned int handle = (unsigned int)luaL_checkinteger(L, 1);
    size_t len = 0;
    const char *data = luaL_checklstring(L, 2, &len);

    proc_entry_t *p = proc_find(handle);
    if (!p || p->stdin_fd < 0) {
        lua_pushinteger(L, -1);
        return 1;
    }

    // Write in non-blocking mode — may get EAGAIN or partial write
    ssize_t written = write(p->stdin_fd, data, len);
    if (written < 0) {
        if (errno == EPIPE || errno == EBADF) {
            // Process closed stdin or fd is bad — mark as closed
            close(p->stdin_fd);
            p->stdin_fd = -1;
            lua_pushinteger(L, -1);  // permanent error
        } else {
            // EAGAIN: no space in pipe right now, caller should retry later
            lua_pushinteger(L, 0);
        }
    } else {
        lua_pushinteger(L, (lua_Integer)written);
    }
    return 1;
}

// ============================================================================
// execute.set_timeout(handle, seconds) -> bool
//   Set a timeout after which the process will be killed with SIGKILL.
//   Use 0 to disable timeout.
// ============================================================================
static int l_execute_set_timeout(lua_State *L)
{
    unsigned int handle = (unsigned int)luaL_checkinteger(L, 1);
    int seconds = (int)luaL_checkinteger(L, 2);

    proc_entry_t *p = proc_find(handle);
    if (!p) {
        lua_pushboolean(L, 0);
        return 1;
    }

    if (seconds > 0) {
        p->timeout_at = time(NULL) + seconds;
    } else {
        p->timeout_at = 0;
    }
    lua_pushboolean(L, 1);
    return 1;
}

// ============================================================================
// execute.close_stdin(handle) -> bool
//   Close stdin (send EOF to process). Returns true if found.
// ============================================================================
static int l_execute_close_stdin(lua_State *L)
{
    unsigned int handle = (unsigned int)luaL_checkinteger(L, 1);
    proc_entry_t *p = proc_find(handle);
    if (!p) {
        lua_pushboolean(L, 0);
        return 1;
    }

    if (p->stdin_fd >= 0) {
        close(p->stdin_fd);
        p->stdin_fd = -1;
    }
    lua_pushboolean(L, 1);
    return 1;
}

// ============================================================================
// Module registration
// ============================================================================
static const luaL_Reg execute_functions[] = {
    {"start",        l_execute_start},
    {"poll",         l_execute_poll},
    {"status",       l_execute_status},
    {"kill",         l_execute_kill},
    {"list",         l_execute_list},
    {"cleanup",      l_execute_cleanup},
    {"write",        l_execute_write},
    {"set_timeout",  l_execute_set_timeout},
    {"close_stdin",  l_execute_close_stdin},
    {NULL, NULL}
};

// Called once when module loads — saves L for callback refs
LUALIB_API int luaopen_execute(lua_State *L)
{
    // Lua 5.1 compatible (GMod uses LuaJIT 2.x / Lua 5.1)
    // luaL_register creates table, registers funcs, sets global "execute"
    luaL_register(L, "execute", execute_functions);
    return 1;
}

__attribute__((visibility("default")))
int gmod13_open(lua_State *L)
{
    return luaopen_execute(L);
}

__attribute__((visibility("default")))
int gmod13_close(lua_State *L)
{
    (void)L;  // callback refs now stored per-entry (p->L)
    // Non-blocking cleanup: signal all, try to reap, give up on stragglers.
    // We cannot block the main thread — server stays alive.
    // Stragglers (orphaned children) will be reaped by init/systemd when
    // the server process eventually exits.

    // Phase 1: SIGTERM
    proc_entry_t *p = g_procs;
    while (p) {
        if (!p->done) {
            kill(p->pid, SIGTERM);
        }
        p = p->next;
    }

    // Phase 2: reap any that already exited (non-blocking)
    p = g_procs;
    while (p) {
        if (!p->done) {
            int st = 0;
            if (waitpid(p->pid, &st, WNOHANG) > 0) {
                p->done = 1;
            }
        }
        p = p->next;
    }

    // Phase 3: SIGKILL remaining (non-blocking, no wait — accept orphan)
    p = g_procs;
    while (p) {
        if (!p->done) {
            kill(p->pid, SIGKILL);
        }
        proc_entry_t *next = p->next;
        free(p->cmd);
        if (p->stdin_fd >= 0) close(p->stdin_fd);
        if (p->stdout_fd >= 0) close(p->stdout_fd);
        if (p->stderr_fd >= 0) close(p->stderr_fd);
        dynbuf_free(&p->out);
        dynbuf_free(&p->err);
        if (p->callback_ref != LUA_NOREF && p->callback_ref != LUA_REFNIL) {
            luaL_unref(p->L, LUA_REGISTRYINDEX, p->callback_ref);
        }
        free(p);
        p = next;
    }
    g_procs = NULL;
    return 0;
}
