#!/bin/bash
set -e

GIT_SRC_DIR="${1:?source dir missing}"
GIT_BUILD_DIR="${2:?build dir missing}"
GIT_OUTPUT="${3:?output path missing}"
GIT_LIBEXEC_OUTPUT="${4:?libexec output path missing}"
BUILD_ARCH="${5:-64}"

CFLAGS_ARCH=""
LDFLAGS_ARCH=""
EXTRA_LIBS=""
if [ "$BUILD_ARCH" = "32" ]; then
    CFLAGS_ARCH="-m32"
    LDFLAGS_ARCH="-m32"
    # 32-bit static linking requires extra libs for glibc NSS functions
    EXTRA_LIBS="-ldl -lpthread -lnsl"
fi

rm -rf "$GIT_BUILD_DIR"
mkdir -p "$GIT_BUILD_DIR"
mkdir -p "$(dirname "$GIT_OUTPUT")"

cp -a "$GIT_SRC_DIR/." "$GIT_BUILD_DIR/"
cd "$GIT_BUILD_DIR"

# Build static curl from source with minimal features
CURL_INSTALL="$GIT_BUILD_DIR/curl_static"

echo "=== Building static curl ==="
curl_version="8.7.1"
curl_tag="curl-8_7_1"

# Download release tarball (has pre-generated configure, unlike shallow clone)
wget -q "https://github.com/curl/curl/releases/download/$curl_tag/curl-$curl_version.tar.gz" \
    -O "$GIT_BUILD_DIR/curl.tar.gz"
tar xzf "$GIT_BUILD_DIR/curl.tar.gz" -C "$GIT_BUILD_DIR"

cd "$GIT_BUILD_DIR/curl-$curl_version"
./configure \
    --prefix="$CURL_INSTALL" \
    --disable-shared \
    --enable-static \
    --with-openssl \
    --without-gssapi \
    --without-libidn2 \
    --without-libpsl \
    --without-libssh2 \
    --without-nghttp2 \
    --without-librtmp \
    --without-libldap \
    --without-zstd \
    --without-brotli \
    CFLAGS="-O2 $CFLAGS_ARCH" \
    LDFLAGS="-static $LDFLAGS_ARCH"
make -j4 install > "$GIT_BUILD_DIR/curl_build.log" 2>&1 || {
    echo "=== Curl build FAILED ==="
    tail -30 "$GIT_BUILD_DIR/curl_build.log"
    exit 1
}

cd "$GIT_BUILD_DIR"

# Build curl-config that matches our custom static curl
mkdir -p bin
cat > bin/curl-config << CUREOF
#!/bin/sh
case "\$1" in
    --libs)    echo "-L$CURL_INSTALL/lib -lcurl -lssl -lcrypto -lz -ldl -lpthread" ;;
    --cflags)  echo "-I$CURL_INSTALL/include" ;;
    --vernum)  echo "080701" ;;
    --prefix)  echo "$CURL_INSTALL" ;;
    *)         ;;
esac
CUREOF
chmod +x bin/curl-config

# Fix: The original script used LIBS="$EXTRA_LIBS" for 32-bit, which REPLACED
# libgit.a entirely — causing ALL symbols from core git to be missing
# (error_errno, the_repository, strbuf_*, etc.).
# Instead, pass LIBS as '$(LIB_FILE) $(EXTLIBS)' + extra libs so libgit.a
# stays in the link line. error_errno is provided by libgit.a(usage.o).
MAKE_LIBS='$(LIB_FILE) $(EXTLIBS)'
if [ -n "$EXTRA_LIBS" ]; then
    MAKE_LIBS="$MAKE_LIBS $EXTRA_LIBS"
fi

make -j4 \
    NO_TCLTK=1 NO_PERL=1 NO_PYTHON=1 \
    CFLAGS="-static -O2 $CFLAGS_ARCH" \
    LDFLAGS="-static $LDFLAGS_ARCH" \
    CURL_CONFIG="$GIT_BUILD_DIR/bin/curl-config" \
    prefix="$GIT_BUILD_DIR/install" \
    LIBS="$MAKE_LIBS" \
    install > "$GIT_BUILD_DIR/git_build.log" 2>&1 || {
    echo "=== Git build FAILED ==="
    tail -100 "$GIT_BUILD_DIR/git_build.log"
    exit 1
}

cp "$GIT_BUILD_DIR/install/bin/git" "$GIT_OUTPUT"

if [ -d "$GIT_BUILD_DIR/install/libexec" ]; then
    cp -r "$GIT_BUILD_DIR/install/libexec" "$GIT_LIBEXEC_OUTPUT"
    echo "=== Git build successful (with libexec) ==="
else
    echo "WARNING: libexec directory not found, creating empty placeholder"
    mkdir -p "$GIT_LIBEXEC_OUTPUT"
    touch "$GIT_LIBEXEC_OUTPUT/.placeholder"
    echo "=== Git build successful (no libexec) ==="
fi
