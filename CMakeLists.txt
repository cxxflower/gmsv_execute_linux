cmake_minimum_required(VERSION 3.5.1)

# Architecture selection: 64 (default) or 32
set(BUILD_ARCH "64" CACHE STRING "Target architecture: 64 or 32")
set_property(CACHE BUILD_ARCH PROPERTY STRINGS "64" "32")

if(BUILD_ARCH STREQUAL "32")
    project(gmsv_execute C)
    set(TARGET_ARCH_SUFFIX "linux")
    set(ENV{PKG_CONFIG_LIBDIR} "/usr/lib/i386-linux-gnu/pkgconfig:/usr/share/pkgconfig:/usr/lib/pkgconfig")
    set(ENV{PKG_CONFIG_ALLOW_SYSTEM_LIBS} "1")
    set(CMAKE_PREFIX_PATH "/usr/lib/i386-linux-gnu" ${CMAKE_PREFIX_PATH})
    set(CMAKE_LIBRARY_PATH "/usr/lib/i386-linux-gnu" ${CMAKE_LIBRARY_PATH})
    set(CMAKE_LIBRARY_ARCHITECTURE "i386-linux-gnu")
    set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -m32")
    set(CMAKE_EXE_LINKER_FLAGS "${CMAKE_EXE_LINKER_FLAGS} -m32")
    set(CMAKE_SHARED_LINKER_FLAGS "${CMAKE_SHARED_LINKER_FLAGS} -m32")
else()
    project(gmsv_execute C)
    set(TARGET_ARCH_SUFFIX "linux64")
endif()

# Build statically linked git
set(GIT_INSTALL_DIR "${CMAKE_BINARY_DIR}/git_static")

# RPATH for runtime
if(BUILD_ARCH STREQUAL "32")
    set(TARGET_RPATH "bin;bin/linux_32;garrysmod/bin")
else()
    set(TARGET_RPATH "bin/linux64;linux64")
endif()

# Create the gmsv module shared library
add_library(gmsv_execute_${TARGET_ARCH_SUFFIX} MODULE src/gm_execute.c)

set_target_properties(gmsv_execute_${TARGET_ARCH_SUFFIX} PROPERTIES
    C_STANDARD 99
    C_STANDARD_REQUIRED ON
    PREFIX ""
    OUTPUT_NAME "gmsv_execute_${TARGET_ARCH_SUFFIX}"
    SUFFIX ".dll"
    POSITION_INDEPENDENT_CODE ON
    C_VISIBILITY_PRESET hidden
    INSTALL_RPATH "${TARGET_RPATH}"
    SKIP_BUILD_RPATH TRUE
    BUILD_WITH_INSTALL_RPATH TRUE
    INSTALL_RPATH_USE_LINK_PATH FALSE
)

# Include paths for Lua headers
target_include_directories(gmsv_execute_${TARGET_ARCH_SUFFIX} PRIVATE
    ${CMAKE_SOURCE_DIR}/thirdparty/luajit/src
)

# Dummy shared library: exports lua_* stub symbols
# The main module links against this dynamically (visible in ldd)
# At runtime in GMod, lua_shared.so overrides these with real symbols
add_library(lua_shared SHARED src/lua_stub.c)
if(BUILD_ARCH STREQUAL "32")
    set_target_properties(lua_shared PROPERTIES
        PREFIX ""
        OUTPUT_NAME "lua_shared_srv"
        SUFFIX ".so"
        POSITION_INDEPENDENT_CODE ON
        C_VISIBILITY_PRESET default
    )
else()
    set_target_properties(lua_shared PROPERTIES
        PREFIX ""
        SUFFIX ".so"
        POSITION_INDEPENDENT_CODE ON
        C_VISIBILITY_PRESET default
    )
endif()

target_link_libraries(gmsv_execute_${TARGET_ARCH_SUFFIX} PRIVATE
    lua_shared
)

# ============================================================================
# Static git build from local sources
# ============================================================================
set(GIT_SRC_DIR "${CMAKE_SOURCE_DIR}/thirdparty/git")
set(GIT_BUILD_DIR "${CMAKE_BINARY_DIR}/git_build")
set(GIT_OUTPUT "${CMAKE_BINARY_DIR}/output/git")
set(GIT_LIBEXEC_OUTPUT "${CMAKE_BINARY_DIR}/output/git-libexec")

add_custom_command(
    OUTPUT ${GIT_OUTPUT} ${GIT_LIBEXEC_OUTPUT}
    COMMAND bash ${CMAKE_SOURCE_DIR}/scripts/build_git.sh ${GIT_SRC_DIR} ${GIT_BUILD_DIR} ${GIT_OUTPUT} ${GIT_LIBEXEC_OUTPUT} ${BUILD_ARCH}
    COMMENT "Building static git (full) with all helpers"
)

add_custom_target(copy_git ALL DEPENDS ${GIT_OUTPUT} ${GIT_LIBEXEC_OUTPUT})

# ============================================================================
# Static ssh (client only) build from local sources
# ============================================================================
set(SSH_SRC_DIR "${CMAKE_SOURCE_DIR}/thirdparty/openssh-portable")
set(SSH_BUILD_DIR "${CMAKE_BINARY_DIR}/ssh_build")
set(SSH_OUTPUT "${CMAKE_BINARY_DIR}/output/ssh")
set(SSH_KEYGEN_OUTPUT "${CMAKE_BINARY_DIR}/output/ssh-keygen")

add_custom_command(
    OUTPUT ${SSH_OUTPUT} ${SSH_KEYGEN_OUTPUT}
    COMMAND bash ${CMAKE_SOURCE_DIR}/scripts/build_ssh.sh ${SSH_SRC_DIR} ${SSH_BUILD_DIR} ${SSH_OUTPUT} ${BUILD_ARCH}
    COMMENT "Building static ssh client and ssh-keygen"
)

add_custom_target(copy_ssh ALL DEPENDS ${SSH_OUTPUT} ${SSH_KEYGEN_OUTPUT})
