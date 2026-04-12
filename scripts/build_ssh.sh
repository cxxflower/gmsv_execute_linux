#!/bin/bash
set -e

SSH_SRC_DIR="${1:?source dir missing}"
SSH_BUILD_DIR="${2:?build dir missing}"
OUTPUT="${3:?output path missing}"
BUILD_ARCH="${4:-64}"

CFLAGS_ARCH=""
LDFLAGS_ARCH=""
if [ "$BUILD_ARCH" = "32" ]; then
    CFLAGS_ARCH="-m32"
    LDFLAGS_ARCH="-m32"
fi

rm -rf "$SSH_BUILD_DIR"
mkdir -p "$SSH_BUILD_DIR"
cp -a "$SSH_SRC_DIR/." "$SSH_BUILD_DIR/"
cd "$SSH_BUILD_DIR"

# -------------------------------------------------------------------
# Override getpwuid / getpwnam.
#
# In a static build on a container uid (e.g. 999) there is no
# /etc/passwd entry, so libc's getpwuid returns NULL and ssh aborts.
#
# We provide our own getpwuid/getpwnam that always returns a fake
# passwd struct.  The home directory is resolved from
# /proc/self/exe so that ~/.ssh lives next to the ssh binary:
#
#   /home/container/ssh          ← binary
#   /home/container/ssh/.ssh/    ← keys, known_hosts, config
# -------------------------------------------------------------------
mkdir -p override
cat > override/fake_passwd.c << 'ENDOFSRC'
#include <sys/types.h>
#include <pwd.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static struct passwd  fake_pw;
static char           fake_pw_name[]   = "unknown";
static char           fake_pw_passwd[] = "x";
static char           fake_pw_gecos[]  = "Unknown User";
static char           fake_pw_shell[]  = "/bin/sh";
static char           exe_home[4096];
static int            fake_pw_ready    = 0;

/* Lazily resolve the directory that contains this executable. */
static const char *
get_exe_home(void)
{
	ssize_t len;
	char *slash;

	if (fake_pw_ready)
		return fake_pw.pw_dir;

	len = readlink("/proc/self/exe", exe_home, sizeof(exe_home) - 1);
	if (len > 0) {
		exe_home[len] = '\0';
		/* strip binary name → directory */
		slash = strrchr(exe_home, '/');
		if (slash)
			*(slash + 1) = '\0';
	} else {
		/* fallback: current working directory */
		if (getcwd(exe_home, sizeof(exe_home)) == NULL)
			strncpy(exe_home, ".", sizeof(exe_home));
		else {
			size_t l = strlen(exe_home);
			if (l > 0 && l + 1 < sizeof(exe_home)) {
				exe_home[l]     = '/';
				exe_home[l + 1] = '\0';
			}
		}
	}

	memset(&fake_pw, 0, sizeof(fake_pw));
	fake_pw.pw_uid    = getuid();
	fake_pw.pw_gid    = getgid();
	fake_pw.pw_name   = fake_pw_name;
	fake_pw.pw_passwd = fake_pw_passwd;
	fake_pw.pw_gecos  = fake_pw_gecos;
	fake_pw.pw_dir    = exe_home;
	fake_pw.pw_shell  = fake_pw_shell;
	fake_pw_ready = 1;

	return fake_pw.pw_dir;
}

struct passwd *
getpwuid(uid_t uid)
{
	get_exe_home();
	fake_pw.pw_uid = uid;
	fake_pw.pw_gid = uid;
	return &fake_pw;
}

struct passwd *
getpwnam(const char *name)
{
	(void)name;
	get_exe_home();
	return &fake_pw;
}
ENDOFSRC

${CC:-cc} -static -O2 -fPIC $CFLAGS_ARCH -c override/fake_passwd.c -o override/fake_passwd.o

# -------------------------------------------------------------------
# Patch includes.h: avoid duplicate #endif
# -------------------------------------------------------------------
LINES=$(wc -l < includes.h)
head -n $((LINES - 1)) includes.h > includes.h.patched

cat >> includes.h.patched << 'ENDOFPATCH'

#endif /* INCLUDES_H */
ENDOFPATCH

mv includes.h.patched includes.h

echo "=== includes.h patched ==="
tail -5 includes.h
echo "=========================="

autoreconf -f -i

# Inject the override object via LDFLAGS so it appears BEFORE all ssh
# .o files on the link line.  Object files (not archives) are always
# pulled in by the linker, and because ours comes first it supplies
# the definitive getpwuid / getpwnam symbols.
CFLAGS="-static -O2 $CFLAGS_ARCH" \
LDFLAGS="-static $LDFLAGS_ARCH ${SSH_BUILD_DIR}/override/fake_passwd.o" \
./configure \
    --prefix="$SSH_BUILD_DIR/install" \
    --without-zlib \
    --sysconfdir=/etc/ssh

make -j4 ssh ssh-keygen

mkdir -p "$(dirname "$OUTPUT")"
cp "$SSH_BUILD_DIR/ssh" "$OUTPUT"
cp "$SSH_BUILD_DIR/ssh-keygen" "${OUTPUT}-keygen"
