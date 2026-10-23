cmake_minimum_required(VERSION 3.22.1)
project(vortx_community_js C)

# Official QuickJS 2026-06-04 source release from bellard.org. The SHA-256 is pinned so a changed
# archive fails configuration instead of silently compiling different untrusted-code semantics.
include(FetchContent)
FetchContent_Declare(quickjs_source
    URL https://bellard.org/quickjs/quickjs-2026-06-04.tar.xz
    URL_HASH SHA256=b376e839b322978313d929fd20663b11ba58b75df5a46c126dd19ea2fa70ad2a
)
# Supported on CMake 4: populate this Makefile-only archive without adding a subproject.
FetchContent_MakeAvailable(quickjs_source)

add_library(quickjs_runtime STATIC
    ${quickjs_source_SOURCE_DIR}/quickjs.c
    ${quickjs_source_SOURCE_DIR}/dtoa.c
    ${quickjs_source_SOURCE_DIR}/cutils.c
    ${quickjs_source_SOURCE_DIR}/libregexp.c
    ${quickjs_source_SOURCE_DIR}/libunicode.c
)
target_include_directories(quickjs_runtime PUBLIC ${quickjs_source_SOURCE_DIR})
target_compile_definitions(quickjs_runtime PRIVATE CONFIG_VERSION="2026-06-04" _GNU_SOURCE)
target_compile_options(quickjs_runtime PRIVATE -Wno-sign-compare -Wno-missing-field-initializers)

add_library(vortx_community_js SHARED vortx_community_js.c)
target_include_directories(vortx_community_js PRIVATE ${quickjs_source_SOURCE_DIR})
target_link_libraries(vortx_community_js quickjs_runtime log m)
target_compile_options(vortx_community_js PRIVATE -fvisibility=hidden -fstack-protector-strong)
# The interpreter is an implementation detail. Keep only the Android loader entry point in the dynamic
# symbol table so no other process component can bind an unintended QuickJS surface.
target_link_options(vortx_community_js PRIVATE "-Wl,--version-script=${CMAKE_CURRENT_SOURCE_DIR}/exports.map")
