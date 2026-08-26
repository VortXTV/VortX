cmake_minimum_required(VERSION 3.22.1)

project(vortx_mpv_seam CXX)

# VortX seam build of the forked libmpv-android JNI glue (see README.md for provenance). The glue is
# compiled FROM SOURCE here; the heavy libmpv/ffmpeg binaries are NEVER rebuilt or vendored -- they
# keep coming from the dev.jdtech.mpv:libmpv:1.0.0 AAR (the same supply chain as before this module
# existed). The AAR is resolved + its jni/<abi> .so files extracted by the Gradle task in this
# module's build.gradle.kts into ${MPV_AAR_JNI_DIR}, purely so the linker can resolve symbols; at
# runtime those same AAR-packaged .so files are what the app loads.
if(NOT DEFINED MPV_AAR_JNI_DIR)
    message(FATAL_ERROR "MPV_AAR_JNI_DIR is not set. The Gradle build must pass -DMPV_AAR_JNI_DIR=<dir with the extracted dev.jdtech.mpv:libmpv jni/<abi> libs>.")
endif()

set(MPV_IMPORTED_LIB "${MPV_AAR_JNI_DIR}/${ANDROID_ABI}/libmpv.so")
set(AVCODEC_IMPORTED_LIB "${MPV_AAR_JNI_DIR}/${ANDROID_ABI}/libavcodec.so")
# Fail closed at configure time with a precise message rather than a bare linker error later.
if(NOT EXISTS "${MPV_IMPORTED_LIB}")
    message(FATAL_ERROR "libmpv.so not found for ABI ${ANDROID_ABI} under ${MPV_AAR_JNI_DIR}. Run the extractMpvAarJniLibs Gradle task wiring (build.gradle.kts).")
endif()
if(NOT EXISTS "${AVCODEC_IMPORTED_LIB}")
    message(FATAL_ERROR "libavcodec.so not found for ABI ${ANDROID_ABI} under ${MPV_AAR_JNI_DIR}. Run the extractMpvAarJniLibs Gradle task wiring (build.gradle.kts).")
endif()

# Public client-API headers vendored verbatim from the SAME mpv tag the AAR bundles (0.41.0; ISC --
# see include/mpv/README.md). They are compile-time only; nothing from them is repackaged.
include_directories(${CMAKE_CURRENT_SOURCE_DIR}/include)

add_library(mpv SHARED IMPORTED)
set_target_properties(mpv PROPERTIES IMPORTED_LOCATION "${MPV_IMPORTED_LIB}")

add_library(avcodec SHARED IMPORTED)
set_target_properties(avcodec PROPERTIES IMPORTED_LOCATION "${AVCODEC_IMPORTED_LIB}")

add_library(
    vortx_mpv_seam
    SHARED
    main.cpp render.cpp log.cpp jni_utils.cpp property.cpp event.cpp
)

target_link_libraries(vortx_mpv_seam mpv avcodec log)
