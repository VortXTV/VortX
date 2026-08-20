cmake_minimum_required(VERSION 3.22.1)
project(vortx_community_js C)

# Official QuickJS 2025-09-13 source release from bellard.org. The SHA-256 is pinned so a changed
# archive fails configuration instead of silently compiling different untrusted-code semantics.
include(FetchContent)
FetchContent_Declare(quickjs_source
    URL https://bellard.org/quickjs/quickjs-2025-09-13.tar.xz
    URL_HASH SHA256=6f1f322aea3bb3a90858db85c9fe717013fde4df7dfcafe2f57e78f5bb4b4a0c
)
FetchContent_GetProperties(quickjs_source)
if(NOT quickjs_source_POPULATED)
    FetchContent_Populate(quickjs_source)
endif()

add_library(quickjs_runtime STATIC
    ${quickjs_source_SOURCE_DIR}/quickjs.c
    ${quickjs_source_SOURCE_DIR}/dtoa.c
    ${quickjs_source_SOURCE_DIR}/cutils.c
    ${quickjs_source_SOURCE_DIR}/libregexp.c
    ${quickjs_source_SOURCE_DIR}/libunicode.c
)
target_include_directories(quickjs_runtime PUBLIC ${quickjs_source_SOURCE_DIR})
target_compile_definitions(quickjs_runtime PRIVATE CONFIG_VERSION="2025-09-13" _GNU_SOURCE)
target_compile_options(quickjs_runtime PRIVATE -Wno-sign-compare -Wno-missing-field-initializers)

add_library(vortx_community_js SHARED vortx_community_js.c)
target_include_directories(vortx_community_js PRIVATE ${quickjs_source_SOURCE_DIR})
target_link_libraries(vortx_community_js quickjs_runtime log m)
target_compile_options(vortx_community_js PRIVATE -fvisibility=hidden -fstack-protector-strong)
