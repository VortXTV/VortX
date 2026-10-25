#!/bin/bash -e

## Dependency versions

v_platform=android-37.0
v_sdk=14742923_latest
v_ndk=30.0.16248370
v_sdk_build_tools=37.0.0
v_cmake=4.1.2

v_lua=5.2.4
# Official full archive SHA-256: https://www.lua.org/ftp/ . mpv0.41 requires Lua<5.3.
v_lua_sha256=b9e2e4aad6789b3b63a056d442f7b39f0ecfca3ae0f1fc0ae4e9614401b69f4b
v_libunibreak=8_0
v_libunibreak_sha256=9c4fad6e517338a098373acc9f35579ae2c325e6446666fb9ac2666ba15ceba4
v_libass=0.17.5
v_libass_sha=4a05d8127f525943ebf45fdc6497c9e665947f0d
v_harfbuzz=14.6.0
v_harfbuzz_sha=c7a7457b7385f33178e8cf87615ca077a810bbe7
v_fribidi=1.0.17
v_fribidi_sha=b93119f5fdc7ea47672cc304c1455ffa6dfe7536
v_freetype=2-14-3
v_libxml2=2.15.4
v_libxml2_sha=96498992efa48d52b0e8b83058bd88dbdaf153c1
v_fontconfig=2.18.3
v_fontconfig_sha=0f236723a3c26bd9745e32ba2b3ee21e5f809295
v_mbedtls=3.6.7
v_mbedtls_sha=068ff080b369adfac81509f9b57b2afabaf82dc5
# Preserve the selected 5774f40f producer's Apple-aligned custom native base.
v_libplacebo_sha=4c426e466814536def653cb23f1d1c287ea7a7f5
v_dav1d=1.5.4
v_dav1d_sha=54706fc6bc0cdecab7e9593974a4039cc038fca7
v_ffmpeg=9.0.2
v_ffmpeg_sha=946fcce07b6dcd0331c8cc609192aeff5e1924f8
v_mpv_sha=8c67647b50059406c5c0444903597281b81516cf


## Dependency tree
# I would've used a dict but putting arrays in a dict is not a thing

dep_mbedtls=()
dep_dav1d=()
dep_ffmpeg=(mbedtls dav1d libxml2)
dep_freetype2=()
dep_fontconfig=(libxml2 freetype)
dep_fribidi=()
dep_harfbuzz=()
dep_libunibreak=()
dep_libass=(freetype fontconfig fribidi harfbuzz libunibreak)
dep_lua=()
dep_libplacebo=()
dep_mpv=(ffmpeg libass lua libplacebo)
dep_mpv_android=(mpv)
