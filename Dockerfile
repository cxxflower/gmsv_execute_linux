FROM ubuntu:22.04 AS builder

ENV DEBIAN_FRONTEND=noninteractive

RUN dpkg --add-architecture i386 && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
    build-essential \
    cmake \
    pkg-config \
    ca-certificates \
    git \
    gcc-multilib \
    g++-multilib \
    wget \
    perl \
    m4 \
    zlib1g-dev \
    zlib1g-dev:i386 \
    libcurl4-openssl-dev \
    libexpat1-dev \
    libexpat1-dev:i386 \
    libssl-dev \
    libssl-dev:i386 \
    gettext \
    autoconf \
    automake \
    libc6-dev:i386 \
    libnghttp2-dev \
    libkrb5-dev \
    librtmp-dev \
    libldap2-dev \
    libssh2-1-dev \
    libbrotli-dev \
    libzstd-dev \
    liblzma-dev \
    libpsl-dev \
    libidn2-dev \
    libbz2-dev \
    libsasl2-dev \
    libunistring-dev \
    && rm -rf /var/lib/apt/lists/*

# Clone the repository with submodules to guarantee full source tree
# (COPY . /src would fail if submodules are not initialized locally)
RUN git clone --progress https://github.com/cxxflower/gmsv_execute_linux.git /src && \
    cd /src && \
    git submodule set-url thirdparty/luajit https://github.com/LuaJIT/LuaJIT.git && \
    git submodule update --init --recursive

WORKDIR /src

ARG BUILD_ARCH=64
RUN if [ "${BUILD_ARCH}" = "32" ]; then \
        export PKG_CONFIG_LIBDIR=/usr/lib/i386-linux-gnu/pkgconfig:/usr/local/i686/lib/pkgconfig && \
        export CFLAGS="-m32 -I/usr/local/i686/include" && \
        export LDFLAGS="-m32 -L/usr/local/i686/lib"; \
    else \
        export PKG_CONFIG_LIBDIR=/usr/lib/x86_64-linux-gnu/pkgconfig:/usr/local/x86_64/lib/pkgconfig && \
        export CFLAGS="-I/usr/local/x86_64/include" && \
        export LDFLAGS="-L/usr/local/x86_64/lib"; \
    fi && \
    cmake -B build${BUILD_ARCH} -DBUILD_ARCH=${BUILD_ARCH} && \
    cmake --build build${BUILD_ARCH} -j4

# ============================================================================
# Финальный образ — только артефакты
# ============================================================================
FROM ubuntu:22.04 AS artifacts

ARG BUILD_ARCH=64

COPY --from=builder /src/build${BUILD_ARCH}/gmsv_execute_linux*.dll /
COPY --from=builder /src/build${BUILD_ARCH}/output/git /git
COPY --from=builder /src/build${BUILD_ARCH}/output/git-libexec /git-libexec
COPY --from=builder /src/build${BUILD_ARCH}/output/ssh /ssh
COPY --from=builder /src/build${BUILD_ARCH}/output/ssh-keygen /ssh-keygen

CMD ["true"]
