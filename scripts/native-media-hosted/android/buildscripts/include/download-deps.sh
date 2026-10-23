#!/bin/bash -e

. ./include/depinfo.sh

[ -z "$WGET" ] && WGET=wget

mkdir -p deps && cd deps

# mbedtls
[ ! -d mbedtls ] && git clone --depth 1 --branch v$v_mbedtls --recurse-submodules https://github.com/Mbed-TLS/mbedtls.git mbedtls
[ "$(git -C mbedtls rev-parse HEAD)" = "$v_mbedtls_sha" ] || {
    echo "mbedTLS source does not match the reviewed maintenance pin; refusing reuse" >&2
    exit 1
}

# dav1d
[ ! -d dav1d ] && git clone --depth 1 --branch $v_dav1d https://code.videolan.org/videolan/dav1d.git dav1d
[ "$(git -C dav1d rev-parse HEAD)" = "$v_dav1d_sha" ] || {
    echo "dav1d source does not match the reviewed stable pin; refusing reuse" >&2
    exit 1
}

# ffmpeg
[ ! -d ffmpeg ] && git clone --depth 1 --branch n$v_ffmpeg https://github.com/FFmpeg/FFmpeg.git ffmpeg
[ "$(git -C ffmpeg rev-parse HEAD)" = "$v_ffmpeg_sha" ] || {
    echo "FFmpeg source does not match the reviewed maintenance pin; refusing reuse" >&2
    exit 1
}

# freetype2
[ ! -d freetype ] && git clone --depth 1 --branch VER-$v_freetype https://gitlab.freedesktop.org/freetype/freetype.git freetype

# fribidi
[ ! -d fribidi ] && git clone --depth 1 --branch v$v_fribidi https://github.com/fribidi/fribidi.git fribidi
[ "$(git -C fribidi rev-parse HEAD)" = "$v_fribidi_sha" ] || {
    echo "fribidi source does not match the reviewed stable pin; refusing reuse" >&2
    exit 1
}

# harfbuzz
[ ! -d harfbuzz ] && git clone --depth 1 --branch $v_harfbuzz https://github.com/harfbuzz/harfbuzz.git harfbuzz
[ "$(git -C harfbuzz rev-parse HEAD)" = "$v_harfbuzz_sha" ] || {
    echo "harfbuzz source does not match the reviewed stable pin; refusing reuse" >&2
    exit 1
}

# libunibreak
# Verify the exact official release archive before extraction; never reuse unverified sources.
bash -e ../include/download-libunibreak.sh "$v_libunibreak" "$v_libunibreak_sha256"

# libxml2
[ ! -d libxml2 ] && git clone --depth 1 --branch v$v_libxml2 https://gitlab.gnome.org/GNOME/libxml2.git libxml2
[ "$(git -C libxml2 rev-parse HEAD)" = "$v_libxml2_sha" ] || {
    echo "libxml2 source does not match the reviewed stable pin; refusing reuse" >&2
    exit 1
}

# fontconfig
[ ! -d fontconfig ] && git clone --depth 1 --branch $v_fontconfig https://gitlab.freedesktop.org/fontconfig/fontconfig.git fontconfig
[ "$(git -C fontconfig rev-parse HEAD)" = "$v_fontconfig_sha" ] || {
    echo "fontconfig source does not match the reviewed stable pin; refusing reuse" >&2
    exit 1
}

# libass
[ ! -d libass ] && git clone --depth 1 --branch $v_libass https://github.com/libass/libass.git libass
[ "$(git -C libass rev-parse HEAD)" = "$v_libass_sha" ] || {
    echo "libass source does not match the reviewed stable pin; refusing reuse" >&2
    exit 1
}

# lua
# Never silently reuse an old unverified source directory or pipe a response to tar.
bash -e ../include/download-lua.sh "$v_lua" "$v_lua_sha256"

[ ! -d libplacebo ] && git clone --depth 1 --branch v$v_libplacebo --recurse-submodules https://code.videolan.org/videolan/libplacebo.git libplacebo

# mpv
[ ! -d mpv ] && git clone --depth 1 --branch v$v_mpv https://github.com/mpv-player/mpv.git mpv

cd ..
