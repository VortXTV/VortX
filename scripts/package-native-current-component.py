#!/usr/bin/env python3
"""Offline exact-profile candidate packaging; no build, extraction, inspection or promotion."""
import argparse
import base64
import binascii
from collections import deque
import gzip
import hashlib
import io
import json
import lzma
import os
from pathlib import Path
import plistlib
import re
import shlex
import stat
import subprocess
import tarfile
import struct
import tomllib
import unicodedata
import zipfile

CHUNK, MIB = 1024 * 1024, 1024 * 1024
GIT = Path("/usr/bin/git")  # Do not execute a producer-controlled/PATH-selected command.
PROFILE = "original-http-sparse-native-reference-reader-v2-dependencies-openssl410-crypto-subtitles-bluray150-freetype2150-libdovi340-candidate"
PROFILE_MANIFEST_SHA256 = "6defe6abf8d198caab4036c79dc185efbaf94c61282c1108ceb6510bc27d24f8"
NATIVE_UPGRADES_PROFILE = "native-upgrades-openssl410-crypto-subtitles-bluray150-freetype2150-libdovi340-v7"
SHADERC_WRAPPER_VERSION = "2026.1.0"
SHADERC_REMOTE_URL = "https://github.com/mpvkit/libshaderc-build/releases/download/2026.1.0/Libshaderc_combined.xcframework.zip"
SHADERC_SOURCE_SPECS = (
    ("libshaderc.zip", 124322785,
     "d213fa58de7886846fb8cb713ea5213b77654a3ad2ba3d89b1f2fe367d945ba5"),
    ("Libshaderc_combined.xcframework.zip", 61246203,
     "77a3d355993cf53843a394bf58262dab99cdd93f9e6fe31d5ca6e55b03866ce1"),
)
SHADERC_MATRIX = (
    ("ios-arm64", "arm64", "ios"),
    ("ios-arm64_x86_64-simulator", "arm64", "isimulator"),
    ("ios-arm64_x86_64-simulator", "x86_64", "isimulator"),
    ("tvos-arm64_arm64e", "arm64", "tvos"),
    ("tvos-arm64_arm64e", "arm64e", "tvos"),
    ("tvos-arm64_x86_64-simulator", "arm64", "tvsimulator"),
    ("tvos-arm64_x86_64-simulator", "x86_64", "tvsimulator"),
    ("macos-arm64_x86_64", "arm64", "macos"),
    ("macos-arm64_x86_64", "x86_64", "macos"),
)
OPENSSL_BOM_PROFILE = "openssl-4.1.0-source-v1"
OPENSSL_SOURCE_VERSION = "4.1.0"
OPENSSL_SOURCE_SHA = "2f4e3a5fec05394068cfa7379890ab552483a8a6"
OPENSSL_SOURCE_TAG = "openssl-4.1.0"
OPENSSL_ROOT = "openssl-4.1.0-2f4e3a5f"
OPENSSL_OUTPUT_ROOT = "openssl"
OPENSSL_GITLINKS = {
    "cloudflare-quiche": "7ab6a55cfe471267d61e4d28ba43d41defcd87e0",
    "gost-engine": "74b1f4fddbc2d6de969815b1992ddc1ae7c643fe",
    "krb5": "784c38f50e70a739400cdd3f2620bac2e2788e6c",
    "oqs-provider": "c5fb439e4ffd947f24c139232fb04fd71fe3c29e",
    "pkcs11-provider": "eb157e48066fdb2b5735f6f327ed7ae65c51eb6f",
    "pyca-cryptography": "e83bbe58e373536636baaa7c33a64a6e8f04c953",
    "python-ecdsa": "4096fa01715929e08b97e73f3173aee9d57f2a3f",
    "fuzz/corpora": "7e3fb43a75c55275759e8bdb5c32de4b50978eab",
    "tlsfuzzer": "61f45d9701294fd87ef92d2a7e3dfb076653a562",
    "tlslite-ng": "77ef321dde1a9e6bcf94d73c80f8789a770d8031",
    "wycheproof": "3fa63dd0344abb611f1fb1d77e119938603ea230",
}
OPENSSL_CONFIGURE_FLAGS = ("no-async", "no-shared", "no-dso", "no-tests", "no-apps", "no-docs")
OPENSSL_PKG_LIBRARIES = ("libmpv", "FFmpeg", "libshaderc", "vulkan", "lcms2", "libdovi",
                         "openssl", "libunibreak", "libfreetype", "libfribidi", "libharfbuzz",
                         "libass", "libsmbclient", "libplacebo", "libdav1d", "gmp", "nettle",
                         "gnutls", "libuchardet", "libbluray", "libluajit", "libuavs3d")
OPENSSL_MATRIX = (
    ("ios", "arm64", "vortx-apple-ios-arm64", "ios-arm64"),
    ("isimulator", "arm64", "vortx-apple-isimulator-arm64", "ios-arm64_x86_64-simulator"),
    ("isimulator", "x86_64", "vortx-apple-isimulator-x86_64", "ios-arm64_x86_64-simulator"),
    ("tvos", "arm64", "vortx-apple-tvos-arm64", "tvos-arm64_arm64e"),
    ("tvos", "arm64e", "vortx-apple-tvos-arm64e", "tvos-arm64_arm64e"),
    ("tvsimulator", "arm64", "vortx-apple-tvsimulator-arm64", "tvos-arm64_x86_64-simulator"),
    ("tvsimulator", "x86_64", "vortx-apple-tvsimulator-x86_64", "tvos-arm64_x86_64-simulator"),
    ("macos", "arm64", "vortx-apple-macos-arm64", "macos-arm64_x86_64"),
    ("macos", "x86_64", "vortx-apple-macos-x86_64", "macos-arm64_x86_64"),
)
OPENSSL_ENV_KEYS = ("CC", "CXX", "CFLAGS", "CPPFLAGS", "CXXFLAGS", "ASMFLAGS",
                    "LDFLAGS", "PKG_CONFIG_LIBDIR", "PKG_CONFIG_PATH", "PATH",
                    "CURRENT_ARCH", "LC_CTYPE", "AR", "ARFLAGS", "RANLIB",
                    "MAKEFLAGS", "CMAKE_BUILD_PARALLEL_LEVEL", "CARGO_BUILD_JOBS")
OPENSSL_EFFECTIVE_KEYS = ("target", "CC", "CFLAGS", "CPPFLAGS", "CXX", "CXXFLAGS",
                           "LDFLAGS", "AR", "ARFLAGS", "RANLIB", "CROSS_COMPILE",
                           "cflags", "cppflags", "lflags", "lib_cppflags")
OPENSSL_DEFAULT_PATH = "/Library/Frameworks/Python.framework/Versions/Current/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
OPENSSL_OUTPUTS = (("libssl.a", "lib/libssl.a", 512 * MIB),
                   ("libcrypto.a", "lib/libcrypto.a", 512 * MIB),
                   ("opensslv.h", "include/openssl/opensslv.h", MIB))
RECIPE_PATHS = frozenset("""
scripts/assemble-mpvkit-dvfel.sh scripts/build-mpvkit-dvfel.sh
scripts/ffmpeg-response-witness.patch scripts/ffmpeg-response-generation.patch
scripts/mpv-completed-response-observation.patch
scripts/ffmpeg-sent-request-evidence.patch scripts/mpv-sent-request-evidence.patch
scripts/mpv-bounded-prefix-request.patch
scripts/ffmpeg-original-transport-evidence.patch scripts/mpv-original-transport-evidence.patch
scripts/ffmpeg-finite-reference-reader.patch scripts/mpv-finite-reference-reader.patch
scripts/mpv-coreaudio-hotplug-lifecycle.patch scripts/mpv-http-seek-interrupt.patch
scripts/mpv-moltenvk-resize.patch scripts/mpv-original-http-cancel-lifetime.patch
scripts/mpv-original-http-reference-recipe.patch scripts/mpv-original-local-file-witness.patch
scripts/mpv-owned-subtitle-constructor.patch scripts/mpv-owned-subtitle-publication.patch
scripts/mpv-upstream-audio-layout-bounds.patch scripts/mpv-upstream-edition-title-lifetime.patch
scripts/mpv-upstream-gpu-next-seek-reset.patch scripts/mpvkit-dvfel.patch
scripts/native-media-hosted/android-assembly.patch
scripts/native-media-hosted/android/buildscripts/include/depinfo.sh
scripts/native-media-hosted/android/buildscripts/include/download-deps.sh
scripts/native-media-hosted/android/buildscripts/include/download-lua.sh
scripts/native-media-hosted/android/buildscripts/patch.sh
scripts/native-media-hosted/android/buildscripts/patches/ffmpeg/0001-emudhra-spki-distrust.patch
scripts/native-media-hosted/build.sh scripts/native-media-hosted/evidence.py
scripts/verify-mpvkit-dvfel-apple-tls.sh scripts/verify-mpvkit-dvfel-artifacts.sh
scripts/native-media-hosted/android/buildscripts/include/download-libunibreak.sh
scripts/native-media-hosted/android/buildscripts/scripts/ffmpeg.sh
""".split())
RECIPE_PATHS = RECIPE_PATHS | {"scripts/native-media-hosted/dovi-source-policy.json"}
INPUT_MANIFEST = "scripts/native-media-hosted/inputs.sha256"
WORKFLOW = ".github/workflows/native-media-candidates.yml"
OUTPUTS = {"apple": {"apple-candidate.tar.gz", "apple-original-library-zips.tar", "apple-artifact-gate.txt",
                      "apple-shaderc-original-all.zip", "apple-shaderc-original-xcframework.zip",
                      "apple-shaderc-inputs.json", "apple-openssl-builds.json",
                      "apple-crypto-source-gmp.tar.xz", "apple-crypto-source-nettle.tar.gz",
                      "apple-crypto-source-gnutls.tar.xz", "apple-crypto-release-sources.tar",
                      "apple-crypto-release-sources.json", "apple-crypto-chain.json",
                      "apple-subtitle-source-unibreak.tar.gz",
                      "apple-subtitle-source-fribidi.tar.xz",
                      "apple-subtitle-source-harfbuzz.tar.xz", "apple-bluray-source.tar.xz", "apple-freetype-source.tar.gz",
                      "apple-subtitle-release-sources.tar",
                      "apple-subtitle-release-sources.json", "apple-subtitle-builds.json", "apple-dovi-builds.json", "apple-dovi-vendor-crates.tar"},
           "android": {"libmpv-release-candidate.aar", "android-artifact-evidence.json",
                       "android-corresponding-sources.tar.gz", "android-build-configs.tar.gz"}}
PINS = {"mpv": "8c67647b50059406c5c0444903597281b81516cf",
        "ffmpeg": "946fcce07b6dcd0331c8cc609192aeff5e1924f8",
        "libplacebo": "275f7dea27924cdd34ab2e6c20e448b6bc4fab65"}
ANDROID_PINS = dict(PINS, mbedtls="068ff080b369adfac81509f9b57b2afabaf82dc5",
                    dav1d="54706fc6bc0cdecab7e9593974a4039cc038fca7",
                    freetype="0a0221a1347e2f1e07c395263540026e9a0aa7c7",
                    fribidi="b93119f5fdc7ea47672cc304c1455ffa6dfe7536",
                    harfbuzz="35f656a1a2bab548ea7f54a6dd3fba2b09680d14",
                    libxml2="96498992efa48d52b0e8b83058bd88dbdaf153c1",
                    fontconfig="0f236723a3c26bd9745e32ba2b3ee21e5f809295",
                    libass="4a05d8127f525943ebf45fdc6497c9e665947f0d")
WRAPPER = {"apple": "2103893078c5e339073b11737b86f7f22b9c4491",
           "android": "fcf6745703dc1265bca88f12fee8fc355ddf251e"}
# Full-file postcomposition hashes retain cancellation plus owned observation.
CANCEL = {"misc/thread_tools.c": "151102f6fc8584e119317e3526502bbae492353b1c312ae4a8f3aecaee8bdab9",
          "misc/thread_tools.h": "62c7ea467ef911d9665cc4d7ffe28b2b09ea03f152326964056f62dab24acc7f",
          "stream/stream_lavf.c": "650bf7b94771e70a6b934b21e362bc77f66ceb1d23ee684d2b169c6e694544a5",
          "stream/reference_source.h": "1f606a977b55f18fdb9f9fc7f5e4549b5774bef10a06c33b06ab945531909b29",
          "stream/vortx_http_request.h": "d7730cc3492f6eaf6f6f1134fa50331c13e251fb1ddab8e577e1b912b8679dc9"}
RESPONSE = {
    "libavformat/http.c": "d1301474b4389256f9862565a399a8888366a68d2e3630338848289fe8a9c831",
    "libavformat/url.h": "14e3acc5a6715d48edb3dadb2f5248deaa38c36b30ff763e9be4b89edf2b1a0c",
    "libavformat/avio.c": "16bf38abc7a5b5586268c71723041df2b90b7b99a8fbaeb06c8b20926534fe7a",
    "libavformat/tcp.c": "cc9c11534ff5017d5931bb06788f95f10e9809953e5ec1cc03114a3a877cdcce",
    "libavformat/tls.c": "0f07be92b62cefb53c6db5552951c658c756fac36ce22b03ccca8a044f1911f2",
    "libavformat/tls.h": "257c76932de48ed84bf849a44ca9ea6fe85adb93a26bb4f7112b19000084ff19",
    "libavformat/tls_securetransport.c": "b04fb28df85f1ef3883b4927d0bfab4477f400128c122f794ff13b4b9c85bebc",
}
READER_FFMPEG_CREATED = {
    "libavformat/vortx_reference_reader.inc": "a8c74f929942423550dba65f738fd4d2ad2d63d975665f64e6da1b00f5001645",
    "libavformat/vortx_reference_pin.h": "e0ccea8466e28169d0882fd664081baa09d3a39626d5351a31804b6dc4bb4e94",
    "libavformat/vortx_reference_reader_stream.h": "adaeb9d58c20ba3305bce4784205c20d6276ba67a758a9ec7207c850c7ba8d87",
    "libavformat/vortx_reference_sparse.h": "fa5f8e163d9368b30db6a9c7f0c69ed36e91d6a23ca409b7ba468c7d2282751c",
    "libavformat/vortx_reference_sparse.inc": "0e3201c26657765a1e6e7a15fe9db1bcac5cf96a8cb7e9d691533e0f4bf3f15f",
}
READER_MPV = {
    "demux/demux.c": "f5a4cd7bf4e29902ef965e43027755c19ded1423129a3fbe9808ad89e64c0e1c",
    "demux/demux.h": "bee52b38477ce7c8efd9a50e778f720ea8c9eec577afab29998682c26ffe75e2",
    "demux/demux_lavf.c": "d945ae1699d383c3d645d2ab963abb166fd0c19f10a4ab144505e7fbfb0408fb",
    "demux/reference_reader.c": "222ec8920d38971d386470d8172e45a89a52350eb352124ddf954be9409b792b",
    "demux/reference_reader.h": "59d669fb370bc12f01856031b8f9d908eb1d50a927d955ecb1fe0b4484c2407d",
    "demux/reference_reader_internal.h": "ded5dc02785e98934a966de87df4337e4c6aed0275bce26da2017883917f4c8d",
    "demux/demux_mkv.c": "1b7cc4d40efa0620bd10669dc44a7d6b32d0236e2ae2be3510a3bac0829e39c2",
    "demux/reference_mkv.h": "38df7814efc3aa7434e5afe269406a989ab6a5fa22a200aa28149a3ab68e46d9",
    "demux/reference_mkv_reader.c": "3ac442e8ff489d11f4a5df6b86f8d964457753f66ce5f3eb530d7db3746b6f7c",
    "demux/reference_mkv_sparse.h": "4b013b6e794257a576bc01f6becb9d120cb878e0851b2e0bdd2225dcf7b18df2",
    "demux/reference_mkv_sparse_planner.c": "e36c6a879138b26e125f647c9254b41674b22b338ab12838376fe8d38bdae056",
    "demux/reference_mkv_sparse_planner.h": "c88597a42186ceb81f45f1f44b3734469cf06889ea3bf91e4853b861943e84fe",
    "demux/reference_mkv_sparse_worker.c": "5deae68bf3c680aa4898ca6c8e0c0e76aa4628bffa693d0ae2d6dd287d9a5e64",
    "stream/vortx_reference_sparse.h": "fa5f8e163d9368b30db6a9c7f0c69ed36e91d6a23ca409b7ba468c7d2282751c",
    "stream/stream_lavf.c": CANCEL["stream/stream_lavf.c"],
    "stream/reference_source.h": CANCEL["stream/reference_source.h"],
    "stream/vortx_reference_reader_stream.h": "adaeb9d58c20ba3305bce4784205c20d6276ba67a758a9ec7207c850c7ba8d87",
    "player/owned_subtitle.c": "014b93845488ef873a4d29c4c8dd4ada69d244626e7a7b38bac82809989c6b29",
    "player/owned_subtitle.h": "8d2f0ee5c972d1da69213cd80fbe249bcf3f19d9de8a2ef87e241d2f08f06284",
    "player/command.c": "e7a19f392bb69e9d208382f157234ac3c908d22a0d4afee5f372ee8f9d33dade",
    "player/reference_owned.inc": "23ac96bfedefcab2234afa2a6f329a36fac6735effca6798b4043d777b060217",
    "sub/owned_text_slot.h": "63c498dd4bdc9fa9c6d128f1be8f37d7cdf377c853888342897f6639601662f6",
    "sub/osd.c": "9b57ccd08e5777e2bc644cbf8001df0301552edf5cf24e36185a54f4cd667195",
    "sub/dec_sub.c": "6e2137b90fe7f2915a528bdd83426448afbd099229f65342dbfd85d1ba1d347b",
    "sub/dec_sub.h": "cb9b5af7c3f87a8dda584617c1f20a90a9331182d54a50c7e5fb8e64e74b384f",
}
READER_MPV_MESON = {
    "apple": "c2abd8f89a772717fdd4bcdbb4a2236d9fb28eca029acfe84bf12f7333df5a55",
    "android": "32c9a1321883f6a980652173061c9c01727ef83b7a0dfe6e8e3a22364b753d47",
}
MBEDTLS = {"apple": "77d72cb88fc662b984f051335b356abc3e76e97ce39302dde6961ecdbba7a332",
           "android": "7099664b2c15a784db38a0db7956f718862201ef6c02d27779b2fc654b44aeac"}
GITLINKS = {"3rdparty/Vulkan-Headers": "74d8a6cb930c68ef617b202c3ff3c59d919e086b",
            "3rdparty/fast_float": "97b54ca9e75f5303507699d27c6b4f4efe4641a1",
            "3rdparty/glad": "73db193f853e2ee079bf3ca8a64aa2eaf6459043",
            "3rdparty/jinja": "15206881c006c79667fe5154fe80c01c65410679",
            "3rdparty/markupsafe": "297fc8e356e6836a62087949245d09a28e9f1b13",
            "demos/3rdparty/nuklear": "242f35efa067a46c595645eeda7b1771ea1f83b1"}
LIBRARIES = "Libmpv Libavcodec Libavdevice Libavfilter Libavformat Libavutil Libswresample Libswscale Libplacebo lcms2 Libdav1d Libssl Libcrypto gmp nettle hogweed gnutls Libsmbclient Libunibreak Libfribidi Libharfbuzz Libbluray Libfreetype Libdovi".split()
UNSUFFIXED_LIBRARIES = frozenset(("Libplacebo", "lcms2", "Libdav1d", "Libssl", "Libcrypto",
                                  "gmp", "nettle", "hogweed", "gnutls", "Libsmbclient",
                                  "Libunibreak", "Libfribidi", "Libharfbuzz", "Libbluray", "Libfreetype", "Libdovi"))

CRYPTO_SOURCE_PROFILE = "gmp630-nettle400-gnutls3813-release-sources-v1"
CRYPTO_CHAIN_PROFILE = "native-upgrades-crypto-chain-v1"
CRYPTO_PACKAGE_POLICY = "assembled-mpvkit-relative-artifact-closure-v1"
CRYPTO_SOURCE_OUTPUTS = (
    {"id": "gmp", "version": "6.3.0", "archiveRoot": "gmp-6.3.0",
     "filename": "gmp-6.3.0.tar.xz", "compression": "xz", "bytes": 2094196,
     "sha256": "a3c2b80201b89e68616f4ad30bc66aee4927c3ce50e33929ca819d5c43538898",
     "sourceRoot": "gmp-6.3.0-a3c2b802", "url": "https://ftp.gnu.org/gnu/gmp/gmp-6.3.0.tar.xz",
     "output": "apple-crypto-source-gmp.tar.xz"},
    {"id": "nettle", "version": "4.0", "archiveRoot": "nettle-4.0",
     "filename": "nettle-4.0.tar.gz", "compression": "gz", "bytes": None,
     "sha256": "3addbc00da01846b232fb3bc453538ea5468da43033f21bb345cb1e9073f5094",
     "sourceRoot": "nettle-4.0-3addbc00", "url": "https://ftp.gnu.org/gnu/nettle/nettle-4.0.tar.gz",
     "output": "apple-crypto-source-nettle.tar.gz"},
    {"id": "gnutls", "version": "3.8.13", "archiveRoot": "gnutls-3.8.13",
     "filename": "gnutls-3.8.13.tar.xz", "compression": "xz", "bytes": 7275324,
     "sha256": "ffed8ec1bf09c2426d4f14aae377de4753b53e537d685e604e99a8b16ca9c97e",
     "sourceRoot": "gnutls-3.8.13-ffed8ec1",
     "url": "https://www.gnupg.org/ftp/gcrypt/gnutls/v3.8/gnutls-3.8.13.tar.xz",
     "output": "apple-crypto-source-gnutls.tar.xz"},
)
CRYPTO_CAPTURE_TAR_OUTPUT = "apple-crypto-release-sources.tar"
CRYPTO_CAPTURE_RECEIPT_OUTPUT = "apple-crypto-release-sources.json"
CRYPTO_CHAIN_OUTPUT = "apple-crypto-chain.json"
CRYPTO_MAX_ARCHIVE = 8 * MIB
CRYPTO_MAX_UNCOMPRESSED = 512 * MIB
CRYPTO_MAX_MEMBERS = 100000
CRYPTO_MAX_MEMBER = 64 * MIB
CRYPTO_MAX_RECEIPT = 64 * MIB
CRYPTO_MAX_PATH = 4096
CRYPTO_MAX_MTIME = 4102444800
CRYPTO_MAX_MTIME_NS = CRYPTO_MAX_MTIME * 1000000000
CRYPTO_MAX_INLINE_RAW = 16 * MIB
CRYPTO_MAX_READER_JSON = 32 * MIB
CRYPTO_MAX_METADATA_JSON = 8 * MIB
CRYPTO_INLINE_BODY_POLICY = {
    "encoding": "canonical-rfc4648-base64", "recordMaxRawBytes": 4 * MIB,
    "configurationMaxRawBytes": 16 * MIB, "sdkMaxRawBytes": 4 * MIB,
    "aggregateMaxRawBytes": 16 * MIB, "readerMaxJSONBytes": 32 * MIB,
    "metadataMaxJSONBytes": 8 * MIB, "receiptMaxBytes": 64 * MIB,
}
CRYPTO_ACCEPTANCE = "ARCHIVE_AND_PUBLIC_SYMBOL_CORRESPONDENCE_ONLY"
CRYPTO_OPEN_GATES = (
    "mandatory companion release-source authentication/capture must be integrated by the profile caller",
    "actual execution receipts for the captured configured build commands",
    "consumer header/ABI compile and final application link",
    "explicit static gnutls_global_init consumer behavior",
    "physical SMB authentication, signing, encryption and IO behavior",
    "signing, package publication and release acceptance",
)
CRYPTO_INSTALLED_HELPERS = {
    "Sources/BuildScripts/crypto-release-sources.py":
        "3c310499d446eed72eb16521b27c16f718f23e7ab1472dec1fad79cc40ed1537",
    "Sources/BuildScripts/crypto-chain-gate.py":
        "69a180d417c8295d723ec3eb904d93414d668e55e15d9902f93718bdcfbe0485",
}
CRYPTO_MATRIX = (
    ("ios", "arm64", "ios-arm64"),
    ("isimulator", "arm64", "ios-arm64_x86_64-simulator"),
    ("isimulator", "x86_64", "ios-arm64_x86_64-simulator"),
    ("tvos", "arm64", "tvos-arm64_arm64e"),
    ("tvos", "arm64e", "tvos-arm64_arm64e"),
    ("tvsimulator", "arm64", "tvos-arm64_x86_64-simulator"),
    ("tvsimulator", "x86_64", "tvos-arm64_x86_64-simulator"),
    ("macos", "arm64", "macos-arm64_x86_64"),
    ("macos", "x86_64", "macos-arm64_x86_64"),
)
CRYPTO_LIBRARIES = (
    ("gmp", "gmp", "libgmp.a", "gmp"),
    ("nettle", "nettle", "libnettle.a", "nettle"),
    ("hogweed", "nettle", "libhogweed.a", "hogweed"),
    ("gnutls", "gnutls", "libgnutls.a", "gnutls"),
    ("Libsmbclient", "libsmbclient", "libsmbclient.a", "Libsmbclient"),
)
CRYPTO_VERSIONS = {"gmp": "6.3.0", "nettle": "4.0", "hogweed": "4.0",
                   "gnutls": "3.8.13", "Libsmbclient": "4.15.13-2512"}
CRYPTO_SOURCE_PINS = {
    "gmp": {"archive": "gmp-6.3.0.tar.xz",
            "sha256": "a3c2b80201b89e68616f4ad30bc66aee4927c3ce50e33929ca819d5c43538898"},
    "gnutls": {"tag": "3.8.13", "commit": "b390d80208ed60f1b33ad899475951a8efb40ccd",
               "archive": "gnutls-3.8.13.tar.xz",
               "sha256": "ffed8ec1bf09c2426d4f14aae377de4753b53e537d685e604e99a8b16ca9c97e"},
    "nettle": {"tag": "nettle_4.0_release_20260205",
               "commit": "bf13ee9e5024014cfa6d2fc097923afe087e63ba",
               "archive": "nettle-4.0.tar.gz",
               "sha256": "3addbc00da01846b232fb3bc453538ea5468da43033f21bb345cb1e9073f5094"},
}
CRYPTO_SELECTORS = {"gmp": "6.3.0-a3c2b802", "nettle": "4.0-3addbc00",
                    "gnutls": "3.8.13-ffed8ec1"}
CRYPTO_PKG_LIBRARIES = OPENSSL_PKG_LIBRARIES
CRYPTO_DEFAULT_PATH = OPENSSL_DEFAULT_PATH
CRYPTO_PLATFORMS = {
    "ios": ("iphoneos", "ios15.0", "-mios-version-min=15.0", "ios"),
    "isimulator": ("iphonesimulator", "ios15.0-simulator", "-mios-simulator-version-min=15.0", "ios"),
    "tvos": ("appletvos", "tvos15.0", "-mtvos-version-min=15.0", "tvos"),
    "tvsimulator": ("appletvsimulator", "tvos15.0-simulator", "-mtvos-simulator-version-min=15.0", "tvos"),
    "macos": ("macosx", "macos12.0", "-mmacosx-version-min=12.0", "apple"),
}
CRYPTO_CONFIGURE_FLAGS = {
    "gmp": ("--disable-assembly", "--disable-cxx", "--with-pic", "--enable-static",
            "--disable-shared", "--disable-fast-install", "--disable-maintainer-mode"),
    "nettle": ("--disable-assembler", "--disable-openssl", "--disable-gcov", "--disable-documentation",
               "--disable-mini-gmp", "--enable-public-key", "--disable-fat", "--enable-pic",
               "--enable-static", "--disable-shared", "--disable-dependency-tracking"),
    "gnutls": ("--with-included-libtasn1", "--with-included-unistring", "--without-brotli",
               "--without-idn", "--without-p11-kit", "--without-zlib", "--without-zstd",
               "--without-tpm", "--without-tpm2", "--without-leancrypto", "--disable-cxx", "--disable-libdane",
               "--enable-hardware-acceleration", "--disable-openssl-compatibility", "--disable-code-coverage",
               "--disable-doc", "--disable-maintainer-mode", "--disable-manpages", "--disable-nls", "--disable-rpath",
               "--disable-tests", "--disable-tools", "--disable-full-test-suite", "--with-pic", "--enable-static",
               "--disable-shared", "--disable-fast-install", "--disable-dependency-tracking"),
}
CRYPTO_GENERATED = ("Makefile", "config.status", "config.log", "config.h")
CRYPTO_EXTRA_GENERATED = {
    "gmp": ("gmp.h",),
    "nettle": ("config.make", "config.m4", "version.h", "nettle.pc", "hogweed.pc"),
    "gnutls": ("lib/gnutls.pc", "lib/includes/gnutls/gnutls.h"),
}
CRYPTO_INSTALLED_CONFIGURATION = {
    "gmp": {"gmp.h": "include/gmp.h"},
    "nettle": {"version.h": "include/nettle/version.h",
               "nettle.pc": "lib/pkgconfig/nettle.pc", "hogweed.pc": "lib/pkgconfig/hogweed.pc"},
    "gnutls": {"lib/gnutls.pc": "lib/pkgconfig/gnutls.pc",
               "lib/includes/gnutls/gnutls.h": "include/gnutls/gnutls.h"},
}
CRYPTO_MAKE_ARGUMENTS = ("-j1", "AUTOCONF=/usr/bin/false", "AUTOHEADER=/usr/bin/false",
                         "AUTOMAKE=/usr/bin/false", "ACLOCAL=/usr/bin/false")
CRYPTO_REQUIRED_SYMBOLS = {
    "gmp": {"__gmpz_cmp", "__gmpz_init"},
    "nettle": {"nettle_sha256_init", "nettle_version_major"},
    "hogweed": {"nettle_rsa_private_key_init"},
    "gnutls": {"gnutls_check_version", "gnutls_global_init"},
    "Libsmbclient": {"smbc_new_context", "smbc_init_context"},
}
CRYPTO_SMB_PINS = {
    "ios/arm64": (31955240, "1c378176da85ff2386f5c81c903860f8ab258a4e846ddba5bb0febc284f01cd0"),
    "isimulator/arm64": (31948848, "bcb902da9a24ebbd3571bd1d04eeea88b3782e10ad98eee9a2be90e15ddeb795"),
    "isimulator/x86_64": (26473896, "0602a2a2eb8c987677b38a150cdf8b03d0f88f13eb7dd7877cacb4a41d7a5254"),
    "tvos/arm64": (31955264, "4921e4c649589e920e139078219b1a3f01a1fea6cd5bc8b71875d15c09aad252"),
    "tvos/arm64e": (32054336, "0267dfcd4ca93acf1e62bb75bc7509f6640c2367c63da99a3c983ec9ad9d8206"),
    "tvsimulator/arm64": (31948880, "6960f069a31801eb0f0f70eb0efd67239502d5c7081163a9ca38faca226a29fd"),
    "tvsimulator/x86_64": (26474992, "4295cab93d2e40c1234f81a8032d28a0da970643d07cb3c01aaf9b63cd103ef1"),
    "macos/arm64": (31933296, "4f6a36df06ad0e5f36c3106c7c61a1978dbc642a7d27c4f9aceb19540998424f"),
    "macos/x86_64": (27602360, "0c9c03db4279b730b86b505b09c2fedc11b879ee7914ef818c940a38e867ae81"),
}
CRYPTO_SMB_HEADERS = {
    "libsmbclient.h": (125287, "9e0fd2184591f449c79b6bc5b5468443920523ea943440534df04294b940ce1c"),
    "samba/version.h": (421, "d601401634a789612aab95d50295c69713af8fb4ac5addf39dffcc402e978554"),
}

SUBTITLE_SOURCE_PROFILE = "unibreak800-fribidi1017-harfbuzz1500-bluray150-freetype2150-release-sources-v4-pax-ns"
SUBTITLE_SOURCE_OUTPUTS = (
    {"id": "libunibreak", "version": "8.0", "archiveRoot": "libunibreak-8.0",
     "filename": "libunibreak-8.0.tar.gz", "compression": "gz", "bytes": None,
     "maximumBytes": 8 * MIB, "entryPoint": "configure",
     "sha256": "9c4fad6e517338a098373acc9f35579ae2c325e6446666fb9ac2666ba15ceba4",
     "sourceRoot": "libunibreak-8.0-9c4fad6e",
     "url": ("https://github.com/adah1972/libunibreak/releases/download/"
             "libunibreak_8_0/libunibreak-8.0.tar.gz"),
     "output": "apple-subtitle-source-unibreak.tar.gz"},
    {"id": "libfribidi", "version": "1.0.17", "archiveRoot": "fribidi-1.0.17",
     "filename": "fribidi-1.0.17.tar.xz", "compression": "xz", "bytes": 1203284,
     "maximumBytes": 8 * MIB, "entryPoint": "meson.build",
     "sha256": "6949dcde27d41cebad1fd741fcafc36d55a1020d2d872d4a6eb3914caabbada2",
     "sourceRoot": "libfribidi-1.0.17-6949dcde",
     "url": "https://github.com/fribidi/fribidi/releases/download/v1.0.17/fribidi-1.0.17.tar.xz",
     "output": "apple-subtitle-source-fribidi.tar.xz"},
    {"id": "libharfbuzz", "version": "15.0.0", "archiveRoot": "harfbuzz-15.0.0",
     "filename": "harfbuzz-15.0.0.tar.xz", "compression": "xz", "bytes": 20396372,
     "maximumBytes": 32 * MIB, "entryPoint": "meson.build",
     "sha256": "968536e9abd782f07f7954044c0c4020199fcdd39b41d221ec42d2a3be4a44df",
     "sourceRoot": "libharfbuzz-15.0.0-968536e9",
     "url": "https://github.com/harfbuzz/harfbuzz/releases/download/15.0.0/harfbuzz-15.0.0.tar.xz",
     "output": "apple-subtitle-source-harfbuzz.tar.xz"},
    {"id": "libbluray", "version": "1.5.0", "archiveRoot": "libbluray-1.5.0",
     "filename": "libbluray-1.5.0.tar.xz", "compression": "xz", "bytes": 473072,
     "maximumBytes": 473072, "entryPoint": "meson.build",
     "sha256": "f676408e91a5d321abf8b8d4dfdae36205c297dab5c54c3ec519639025f474a2",
     "sourceRoot": "libbluray-1.5.0-f676408e",
     "url": "https://download.videolan.org/pub/videolan/libbluray/1.5.0/libbluray-1.5.0.tar.xz",
     "sourceTransformPolicy": "bluray150-retained-apple-mobile-v1",
     "output": "apple-bluray-source.tar.xz"},
)
SUBTITLE_SOURCE_OUTPUTS = SUBTITLE_SOURCE_OUTPUTS + ({'id': 'libfreetype', 'version': '2.15.0', 'archiveRoot': 'freetype-37515cf56ba3349656049edbed89ffc6f6466f2d', 'filename': 'freetype-37515cf56ba3349656049edbed89ffc6f6466f2d.tar.gz', 'compression': 'gz', 'bytes': 2594500, 'maximumBytes': 2594500, 'entryPoint': 'meson.build', 'sha256': '9efee8b0508e142f38d1c7e2e192d3e5041aa4bbf6c2ab1a901518211f76a914', 'sourceRoot': 'libfreetype-2.15.0-37515cf5', 'url': 'https://gitlab.freedesktop.org/freetype/freetype/-/archive/37515cf56ba3349656049edbed89ffc6f6466f2d/freetype-37515cf56ba3349656049edbed89ffc6f6466f2d.tar.gz', 'sourceTransformPolicy': 'freetype2150-git-membership-empty-dlg-v1', 'output': 'apple-freetype-source.tar.gz'},)

# Official immutable FreeType 2.15.0 Git membership, retained without decoding a source archive.
FREETYPE_SOURCE_COMMIT = '37515cf56ba3349656049edbed89ffc6f6466f2d'
FREETYPE_SOURCE_TREE = '9ae032bd6c9a81300af54b4c9d92b975e1404a5c'
FREETYPE_EMPTY_GITLINKS = {"subprojects/dlg": "395ccad2c1e0daae535c4d20bb0a3f2424648e17"}
FREETYPE_GIT_FILES = {'.clang-format': (420, 'fbd04c11cbf2056a445add4914d0e5693c67b82f'), '.gitignore': (420, 'e4f1510bf9fa53e42ff14b918c79c185c4dba38a'), '.gitlab-ci.yml': (420, '9dc33ae213ed3a501025e9e350b50852716232ca'), '.gitmodules': (420, 'b452dffb93b18b41c75a50de9c08e4b07962ee6e'), '.mailmap': (420, '31d2a47663c122720e4cbad12b5ef874080b1d53'), 'CMakeLists.txt': (420, 'fc8bcc8af939279f0f303ed2989419af12967c10'), 'LICENSE.TXT': (420, '0f9df2177a47a3e463e45d295afdcc783766836e'), 'MSBuild.rsp': (420, '8401e60309f18cf8e4007c99e6b208fd497e8833'), 'MSBuild.sln': (420, 'ba56ae2ef89cdc090d39a6ea4b62d68daecccd37'), 'Makefile': (420, '03c0429837c77cff9a8092991547ae63448af97b'), 'README': (420, '94b8fc7bb13b9e8666dbaf199226d1a6c8883135'), 'README.git': (420, '16cf434dbf970d1830d0d9fd1881527172b092fc'), 'autogen.sh': (493, 'e6f1ebf234af119332b9850b5dda0d78af796f7f'), 'builds/amiga/README': (420, 'afb06c370809cd161b2c01b1fae9e757779265a8'), 'builds/amiga/include/config/ftconfig.h': (420, '90ad5c853ab46f134704fb72bc7c8dc0a228f44f'), 'builds/amiga/include/config/ftmodule.h': (420, '9f76b17a01b3194abba0d61554eb96cc866658b3'), 'builds/amiga/makefile': (420, '8b5a5c0b99a431f9f7b4c426813521c68ecaf996'), 'builds/amiga/makefile.os4': (420, '88fe16f19554092f1005f49ee61cee17d1597c9f'), 'builds/amiga/smakefile': (420, '5edf4bec042367704f18ecab9834b97fa8d7b891'), 'builds/amiga/src/base/ftdebug.c': (420, 'a458bbad1a503a6bf86a1c61046841701b720e53'), 'builds/amiga/src/base/ftsystem.c': (420, '201ef0bde3bb01b049de86e7779a90fd7e1b8742'), 'builds/ansi/ansi-def.mk': (420, '7b4564a667320d6e0e37bb0515d7ea705412c4a5'), 'builds/ansi/ansi.mk': (420, '31a60469d811c9e863507a41dbfea48ebb18ca03'), 'builds/atari/ATARI.H': (420, '4ddd2eb2ebaa1a97a461a1d821677acc6196b045'), 'builds/atari/FNames.SIC': (420, 'f3657179d919530820462ad3ade981da4b356349'), 'builds/atari/FREETYPE.PRJ': (420, '4776a5bc690aadd82efb537fa4ce8eb349845a43'), 'builds/atari/README.TXT': (420, '1300817b2617f1b1f0c6ea4349d94d32dc6c84ea'), 'builds/atari/deflinejoiner.awk': (420, '16d9e6dd9333e05e73a5b2b699c72ab7966d11a9'), 'builds/atari/gen-purec-patch.sh': (493, '1ec050c11fa3cbbba26c610dfa32787f5a995795'), 'builds/beos/beos-def.mk': (420, '55e61eb88cdb61137824eef72e0179805366494b'), 'builds/beos/beos.mk': (420, '7579b187d7cef1ab9c909566b1239f38169cd3fb'), 'builds/beos/detect.mk': (420, 'a045e5ffe0a60b6fc05c2f922228a046c391bfee'), 'builds/cmake/FindBrotliDec.cmake': (420, '97efb8867c09365d4b8f83f91952ae92d89156ae'), 'builds/cmake/FindHarfBuzz.cmake': (420, '0f0e33a1a1feb654f78473d48416315e16f896cb'), 'builds/cmake/iOS.cmake': (420, '8f82d61d34bfb0a69bb64a30a5df8a0a02744ae8'), 'builds/cmake/testbuild.sh': (493, '6d1661386bf6363ac043c39ff00b40d93e63cc31'), 'builds/compiler/ansi-cc.mk': (420, '9fd5b0eb2aa58e697041f6ef5307795bc3a686ab'), 'builds/compiler/bcc-dev.mk': (420, 'f03d16c7799a2a6bca6e95044c8bf92099ad3b1c'), 'builds/compiler/bcc.mk': (420, '24d56e0267703cd770a14c214c268bed1bff5f22'), 'builds/compiler/emx.mk': (420, 'e5c3fdc70dbc73a8269fe0ea788cdad6c7215f4c'), 'builds/compiler/gcc-dev.mk': (420, '691bceb29ed972aa26b9d9c3f219c8e6093f3833'), 'builds/compiler/gcc.mk': (420, 'ab8c55ffabfe2cf10edf5e87ed3a572e0c7bc2fc'), 'builds/compiler/intelc.mk': (420, '1fd53c2d88eb6abceab3eec875c017be6e990e51'), 'builds/compiler/unix-lcc.mk': (420, 'b8b1fbc063ed2388aa15b7a2bb4c8523e010b4d4'), 'builds/compiler/visualage.mk': (420, '8c1dcdb65c9be8f5c1689c5ff8085e33c2de4972'), 'builds/compiler/visualc.mk': (420, '4754c0e97c812363cdecc94776f8d4e6e56b6c2e'), 'builds/compiler/watcom.mk': (420, 'd6d24a49f1c3ac3f252c7d4941f24c7588b3980e'), 'builds/compiler/win-lcc.mk': (420, '06b1644a66534cebbd491d10dd04046102666745'), 'builds/detect.mk': (420, '7c5b97389b1309963211e3f7418155d77e735e27'), 'builds/dos/detect.mk': (420, '1d181240aa92f9bd62e336b7284d43fc98e62588'), 'builds/dos/dos-def.mk': (420, '88f70167fcdd895dfaadfa4979515d302b2136d7'), 'builds/dos/dos-emx.mk': (420, 'f1bc35954cc3f577d9fab04b014b3f2b6545c717'), 'builds/dos/dos-gcc.mk': (420, 'f7bc5551e3a459d7524224cf4f637bce782ee080'), 'builds/dos/dos-wat.mk': (420, '6e096e6493502352ec31ad386edcc326a230d7b4'), 'builds/exports.mk': (420, '1df4010d28d9021adf932b642bc305aba427c4a8'), 'builds/freetype.mk': (420, 'b6ff865b74710df92c5e2fff2b7c3d35c16ee896'), 'builds/link_dos.mk': (420, '923639d489d83816f9e4a3cff881e5fd35117a59'), 'builds/link_std.mk': (420, '008de5170c81a79181d771d1585f6a3fec6a4caf'), 'builds/mac/FreeType.m68k_cfm.make.txt': (420, 'b74565f10796908a89d67644a5405f4cbe6856e9'), 'builds/mac/FreeType.m68k_far.make.txt': (420, 'd880ddbb7c6c54749f8862d0f815575f455a7ef7'), 'builds/mac/FreeType.ppc_carbon.make.txt': (420, '1fa8c307608e7d8f96b598db3c171cea7f2a132a'), 'builds/mac/FreeType.ppc_classic.make.txt': (420, '2550190cbf4ad90ebca1799b541e1038a0c25a66'), 'builds/mac/README': (420, '06e3d51da86ae6f5aab2eeccd8c40866a6f22218'), 'builds/mac/ascii2mpw.py': (493, 'ad32b219772550f2efecb6029ace370cce08aa0c'), 'builds/mac/freetype-Info.plist': (420, '344e5ac0b3a683edefc7191ac79dca1c5208b623'), 'builds/mac/ftlib.prj.xml': (420, 'cbbc45ee55c5c18fe936f5ce3c1fe6fa5970e101'), 'builds/mac/ftmac.c': (420, '77eb874389dd952d7515cf0c4617bcb0f3ffce41'), 'builds/meson/extract_freetype_version.py': (420, '23889620390892d50b09f6f370026e7f34324cd5'), 'builds/meson/extract_libtool_version.py': (420, '4ffdb1a0b61110983b768b624d80397364f7005b'), 'builds/meson/generate_reference_docs.py': (420, '3022e0758c7288b23ab647ca2055d477e840a9e6'), 'builds/meson/parse_modules_cfg.py': (420, '40d30323ba9cbe6d7bc0cb0ebe980af19edbc35d'), 'builds/meson/process_ftoption_h.py': (420, 'd5a217268f7de613a39be8687a0747d3d9cabc4d'), 'builds/modules.mk': (420, 'bcc61f09f9a093bddb7b2af8aa0bc207cbe9ed98'), 'builds/os2/detect.mk': (420, 'dfd15344561572639100e14651ed47287fb87f64'), 'builds/os2/os2-def.mk': (420, '8f7b7d49d941c491c6d697fee722f03fe1a79b93'), 'builds/os2/os2-dev.mk': (420, 'de5d4c906770f0425df2dd3183e4f246946c88be'), 'builds/os2/os2-gcc.mk': (420, 'db681adbfe25ea9fd45af824dd348f700135a8c4'), 'builds/plan9/README': (420, '344750d866d5a5f1f612589f862e4cab033b2371'), 'builds/plan9/p9lib.h': (420, '187e2a1c0b9bdc73164555dd1bd49ec520d1fae9'), 'builds/symbian/bld.inf': (420, '2f28097e4c4401a4ce1c75e488938c803852a89f'), 'builds/symbian/freetype.mmp': (420, '03490acada538c3b006c0d29f4be51f3392f16f9'), 'builds/toplevel.mk': (420, 'aaace59206a201e042b4284abbadb1079f68f560'), 'builds/unix/.gitignore': (420, 'f89b226b81a99c2602b5ba08fc69b0121b93a02e'), 'builds/unix/ax_compare_version.m4': (420, 'ffb4997e8b146e1e40f5da58fee4f4150290f4a4'), 'builds/unix/ax_prog_python_version.m4': (420, 'dbc3dbf1da69eb1bd164b4992bc17c5b3ae3820a'), 'builds/unix/ax_pthread.m4': (420, 'e5858e50c3c45d2444fbd252df5c24496d96d6f1'), 'builds/unix/configure.raw': (420, '9e585c7114a5742f4397bf47357ac20aa61a8153'), 'builds/unix/detect.mk': (420, '2facdf7581c0bd704de7eb5d2fb7032a0a845683'), 'builds/unix/freetype-config.in': (420, '4e69a06725cdac205f5a968e0cc1c8d2f2f6a76a'), 'builds/unix/freetype2.in': (420, 'fe389f4b6fef51f82dc7b938c02e136dbc84318d'), 'builds/unix/freetype2.m4': (420, 'c08ef9eac870c7b8ad30805c91504573dcc2adef'), 'builds/unix/ft-munmap.m4': (420, 'f4df34c5b75a2a49f51841de0576cf9f991e67c6'), 'builds/unix/ftconfig.h.in': (420, '1fc1e28fb5283f38d7c37811c819bfb1e01e6d3c'), 'builds/unix/ftsystem.c': (420, '7575da328b89ee9328991c0945185b587a5a2535'), 'builds/unix/install.mk': (420, '1bfdd1daca7c69b61735e2d89cb107a7bcaf065e'), 'builds/unix/pkg.m4': (420, '260e1fb9221c08bff990281913a81d0389d8c350'), 'builds/unix/unix-cc.in': (420, '15767cb29898f8692833e242585cdae9bff6719b'), 'builds/unix/unix-def.in': (420, '9bf2e2b57235b81e38bfb4a8eb5199f24f0efe2b'), 'builds/unix/unix-dev.mk': (420, '347c922f6af6cf6be9324e512c2f73027e4a5b8a'), 'builds/unix/unix-lcc.mk': (420, 'c0c1978c88eee0946bf4f359e9337a77f2a8947f'), 'builds/unix/unix.mk': (420, '97b29473bcf936b304ef8827316b12a3e9f9af62'), 'builds/unix/unixddef.mk': (420, '223593bae73a03d8309efe084f573ed97cf8084e'), 'builds/vms/apinames_vms.bash': (420, '1928d21ae7376184ccc45d20897ccea4da153ca8'), 'builds/vms/ftconfig.h': (420, 'da4799e3aa63756542538571db1f85b1c0c4ef47'), 'builds/vms/ftsystem.c': (420, 'e325e9c6ed785de85bc4d0b6c8c6b3d0644f8147'), 'builds/vms/patch_ftcalc.sed': (420, '79174183e48986b4c175bab15cc27f1a7283d562'), 'builds/wince/ftdebug.c': (420, '221d7c882e872dad8aa7603ff448c078f8d146b2'), 'builds/wince/vc2005-ce/freetype.sln': (420, '62c6a657bc0112a1e4a5dd736256239389ae4b85'), 'builds/wince/vc2005-ce/freetype.vcproj': (420, 'efdb587021ca03a2d5b2121e3590d4888dbd5c3a'), 'builds/wince/vc2005-ce/index.html': (420, '297ddebf656ed68d21f7d42955838dfcd444fccd'), 'builds/wince/vc2008-ce/freetype.sln': (420, '23914323c9cf194b8a923219cd66059440cb898a'), 'builds/wince/vc2008-ce/freetype.vcproj': (420, 'd01c5b59f13bfac194c0dd973152d19efeeb02b8'), 'builds/wince/vc2008-ce/index.html': (420, '5f21af5ee840db9e90b8c3fa65abe68970d20c58'), 'builds/windows/.gitignore': (420, '41456a48a13bb13f9831f169d6c29c56f74e31f9'), 'builds/windows/detect.mk': (420, '6ca3ca1ac58b37e4db06805bf39bde5e4fe975ab'), 'builds/windows/ftdebug.c': (420, '96bb0688a1b90a37e87533aad5f438083b20fd43'), 'builds/windows/ftsystem.c': (420, '3d20566a72ba6b69633659bfd4e4dae0984ada6a'), 'builds/windows/vc2010/freetype.user.props': (420, '234dd5d7959d01d731fa769d35fa46278b4bd6f4'), 'builds/windows/vc2010/freetype.vcxproj': (420, '4efd9d460ed6ae681715739186051804c8585533'), 'builds/windows/vc2010/freetype.vcxproj.filters': (420, '4085f6c4d9b9c2106af39bcaa535126febd5801c'), 'builds/windows/vc2010/index.html': (420, 'd26745b9ec902b61f84c987f46b771264aee97f8'), 'builds/windows/visualc/freetype.dsp': (420, '540f5b9adee1224ecf551b83546765b61cbba5c2'), 'builds/windows/visualc/freetype.dsw': (420, 'b149e769b5a7a40d9761039b962befded439af22'), 'builds/windows/visualc/freetype.sln': (420, '9054d0abe03ff94d8af5e8edd065564eb9b8ffa3'), 'builds/windows/visualc/freetype.vcproj': (420, '6a5b9d697d8e69361b688a7e6197d02c7fc7f41d'), 'builds/windows/visualc/index.html': (420, '1267573c12615471518f1984b8bb63b64281d178'), 'builds/windows/visualce/freetype.dsp': (420, '714c422574383f357ed32fd4fb8f8836ac861dc1'), 'builds/windows/visualce/freetype.dsw': (420, 'b149e769b5a7a40d9761039b962befded439af22'), 'builds/windows/visualce/freetype.vcproj': (420, 'c4b4533b6bb84a144c8dccca7e11de9b27eb1203'), 'builds/windows/visualce/index.html': (420, '46966fecf2ba471889c14eb942ab20e0a5048519'), 'builds/windows/w32-bcc.mk': (420, '2532479f6e4b9548dff38d6b20761cd99439af06'), 'builds/windows/w32-bccd.mk': (420, 'd63717033679ab942b52ae7b56d8419ef96fb6e5'), 'builds/windows/w32-dev.mk': (420, '905779f68f28a53e667c08446b2a50e4eaa26f63'), 'builds/windows/w32-gcc.mk': (420, '32c2051a065795a668e1a4d9715dd10295bb084d'), 'builds/windows/w32-icc.mk': (420, 'fa1c6ccacc60ecb76867ca31fa84204cbea45105'), 'builds/windows/w32-intl.mk': (420, '6d049412be308116cc2f8fc819806f840121d3d7'), 'builds/windows/w32-lcc.mk': (420, '994612b5397a0ed99d95630e88c541cf40b45798'), 'builds/windows/w32-mingw32.mk': (420, 'd2d8a9e4e29100fa1317290e1cee5b149766cf16'), 'builds/windows/w32-vcc.mk': (420, 'bf4b3735f37c7c57afbbf325218789c1eb3b492a'), 'builds/windows/w32-wat.mk': (420, 'fe287682f6a335ecfa72dce32d3d9b1509d656f8'), 'builds/windows/win32-def.mk': (420, '741422ca782d8c21a88db60e7458e7ccaf91ce76'), 'configure': (493, '672bd44e4c69b16ef36c98134022342e511685da'), 'devel/ft2build.h': (420, 'e94e6c52b70f44af880d0a7eab2bcf87dc918b42'), 'devel/ftoption.h': (420, '8e630ce05f96fbfb657264b164e2f943cdca8138'), 'docs/.gitignore': (420, 'b8d05d11a52f543f5fdbd336f9c3cdc3a751f593'), 'docs/CHANGES': (420, '59f450b14a56c111d1a93b821e76db95a2cd053c'), 'docs/CMAKE': (420, '31237ae15164709f4bc88ed1a8a63d1436d959eb'), 'docs/CUSTOMIZE': (420, '890c8abdd293b99bbea67beaf24d7aeeee299924'), 'docs/DEBUG': (420, '408b52fbc26a671c9ec915e77994741941d6461f'), 'docs/DOCGUIDE': (420, 'd031185267d31a8c09e767f4e91a6a47058b2f16'), 'docs/FTL.TXT': (420, 'b9e8cbd66ffff526113350953f4a2f4252a92f49'), 'docs/GPLv2.TXT': (420, 'b2fe7b6af3535ebc1e018dd2fe6c993330c031fa'), 'docs/INSTALL': (420, 'f576efec85437687be2c5fc4f93aca31bc450e01'), 'docs/INSTALL.ANY': (420, 'd92b27cb504cad034ece99eca1ef73b52e4669e1'), 'docs/INSTALL.CROSS': (420, 'd417fbd12f0711faa788ce5e6032082738e70dd7'), 'docs/INSTALL.GNU': (420, '766f6f8a1cccf0650fbd989f9e203cdc4d663347'), 'docs/INSTALL.MAC': (420, '2587e24a65c94473492873e6f113a3676440600f'), 'docs/INSTALL.UNIX': (420, 'acbd11e6edba0302a3a10711ac20cc5e2b257771'), 'docs/INSTALL.VMS': (420, '4c9a97de0b2a363954686896d6a81eed04d176d8'), 'docs/MAKEPP': (420, '4450e4770069e8bcafa180c0458258265d29e7f6'), 'docs/PROBLEMS': (420, '40bdc35a67629030515b4d7aaa803b5844a4b6a0'), 'docs/README': (420, 'c2b5af865011d6802e44f2406098bdc9c8f79e43'), 'docs/TODO': (420, '7c7987d1dc500e5ab52cacf69d43bf37915a2a64'), 'docs/VERSIONS.TXT': (420, '92a1a3368e16c92162b76809ad92c3cb44d55f17'), 'docs/formats.txt': (420, '13b3eb2a297b837ccb0b7630d1e3767811bf78e3'), 'docs/freetype-config.1': (420, 'e3e873aa60b946d1599b194fd02ef4bb136b0a91'), 'docs/freetype-web.txt': (420, '0c9140c50b383e2f2d601e25302bb695aff08558'), 'docs/markdown/images/favico.ico': (420, '8464e77ad3587b21e6b2dfa38491cc17bd5d6743'), 'docs/markdown/javascripts/extra.js': (420, 'b1ce774fac4076e78d0ba1eb122481ea5fcc6b0e'), 'docs/markdown/stylesheets/extra.css': (420, '5d999ed5d2015b8196b0f3007943b648146d3569'), 'docs/oldlogs/ChangeLog.20': (420, '52142ccb218a4985a0f60133a05055089fce4a1a'), 'docs/oldlogs/ChangeLog.21': (420, 'f2c18777392097e640f63d37e299ab40746a19bc'), 'docs/oldlogs/ChangeLog.210': (420, 'df163d0f7873f450799085484457509e966b7256'), 'docs/oldlogs/ChangeLog.22': (420, '5a5598a00b1c810c3937532e80af8bbc7f11ef6d'), 'docs/oldlogs/ChangeLog.23': (420, '7a5006ea9a3b062b6a60eff79ad9a38b919238b4'), 'docs/oldlogs/ChangeLog.24': (420, 'ba684fc26479c566376dc71cb8ac53643da2a909'), 'docs/oldlogs/ChangeLog.25': (420, '01d61fced5207a0f453fb369680c34bf7167471c'), 'docs/oldlogs/ChangeLog.26': (420, '02b3f9a680061264ef3781e92fee897c86209663'), 'docs/oldlogs/ChangeLog.27': (420, 'f58f84bc5274bb6aba616604ce66bc8148141740'), 'docs/oldlogs/ChangeLog.28': (420, 'e3310fb4dea2d888e3b74add0838a331e2b22aa4'), 'docs/oldlogs/ChangeLog.29': (420, 'b6629a48ac13b78ca882278874bd4e79e3c0d943'), 'docs/raster.txt': (420, '3ba8154fcb79ed87c2e3c359480511c3d76800ab'), 'docs/release': (420, '459f54e9e92eb76deec9164939f0ec9c8365d1a8'), 'include/freetype/config/ftconfig.h': (420, '9800e99adf950bb887e2fba4e851540856c58f3d'), 'include/freetype/config/ftheader.h': (420, '24a9161e2f113e3eb78afb6ca12719f696da5605'), 'include/freetype/config/ftmodule.h': (420, '028e52cc33c675fefafb2d17c7cb83ca208e5580'), 'include/freetype/config/ftoption.h': (420, '6d3d7dfaa574d8387b6eca249b3a13f9f57c0360'), 'include/freetype/config/ftstdlib.h': (420, '1c63e8d654c1c0aa2828ed78f8cb6735cd5688c9'), 'include/freetype/config/integer-types.h': (420, '4ab4c0c78bd34e3eacc66bb0ac27aa5b9cbc889d'), 'include/freetype/config/mac-support.h': (420, 'ac48995320fe9b9e4bd5dad905b2012d0e515ae9'), 'include/freetype/config/public-macros.h': (420, 'c76509a99f7f784390e7895683779b78d3c3fbb4'), 'include/freetype/freetype.h': (420, '0a330c7c3f660795e4e96f1b22970bebd3eee1a2'), 'include/freetype/ftadvanc.h': (420, '876a8a55cb9fc233b0807aff69e1a62acee3cc1a'), 'include/freetype/ftbbox.h': (420, '0107d94986bcc137709c27dfc7acb315750b04dc'), 'include/freetype/ftbdf.h': (420, 'fb1f318648612c4eba7c08e697b8442882d5457a'), 'include/freetype/ftbitmap.h': (420, '1df5f29aca1ab769611b4d4c30a64022015a5dcc'), 'include/freetype/ftbzip2.h': (420, '732931d22714141f32b559bb6d4da7f7373b5555'), 'include/freetype/ftcache.h': (420, '97223e36ec6b3fe99f3d0e77cb305b9d17c46b98'), 'include/freetype/ftchapters.h': (420, '7566fbd10f83de079bea84947b1f7d56fba720f0'), 'include/freetype/ftcid.h': (420, 'f9744716d986da9f510777e3ca2ed116b475205b'), 'include/freetype/ftcolor.h': (420, '1cce747115731210c0f866cc037ad812d70a8961'), 'include/freetype/ftdriver.h': (420, '39635f86c3ecce552d76141d9af12a2acd72b155'), 'include/freetype/fterrdef.h': (420, 'ce3817e55df3ac42a72fcb5b5662830294fda97f'), 'include/freetype/fterrors.h': (420, '218c4610e21800220ef5d7588768eb1d3691e22d'), 'include/freetype/ftfntfmt.h': (420, '2ea0c5f4d708a2cde24fe3d81f969cd10c04c6da'), 'include/freetype/ftgasp.h': (420, '632b536b471a25d84e26f4f816a200b269e0182d'), 'include/freetype/ftglyph.h': (420, 'e967110e81eb7e0c0d1046536611df0dc84b6ce4'), 'include/freetype/ftgxval.h': (420, '546a4818b6cd641b81a15a92b60dcc9d64e50650'), 'include/freetype/ftgzip.h': (420, 'f0c1550f61d36112612183e6a49912a5f57112c8'), 'include/freetype/ftimage.h': (420, '61de54e48cbbe83ef47462314483b6e96bbfdd7f'), 'include/freetype/ftincrem.h': (420, '32637fe5af02e2ae1b1e5c41124ef72e4fe81baa'), 'include/freetype/ftlcdfil.h': (420, '72dbe2acccbb5df2ee78c51668d70d19f4ee4896'), 'include/freetype/ftlist.h': (420, '74b3ffaee9f14b122a5361bfccf81ffded054995'), 'include/freetype/ftlogging.h': (420, '1670b12caf51a2d0f8f7c2954c7b240a68a2492d'), 'include/freetype/ftlzw.h': (420, 'ab2a9b7d5a853a19c2ecb349bc0c118c15db7a48'), 'include/freetype/ftmac.h': (420, 'a3ed7fba6f735a477816f04f235278b978e43617'), 'include/freetype/ftmm.h': (420, 'fb239bda1223a48bae5f4cf8aa982b426df97adc'), 'include/freetype/ftmodapi.h': (420, '7af33e33afee787703a7462b6921a9f4bae608ef'), 'include/freetype/ftmoderr.h': (420, '9010c9fc489a49d378dcbffc80b0bb0ec5e19980'), 'include/freetype/ftotval.h': (420, '66ac5871dcc832b164756e8b9b15097fd0e461c3'), 'include/freetype/ftoutln.h': (420, '68cf65bae15973c543756f342567d8b2e7d60ec4'), 'include/freetype/ftparams.h': (420, '3f6af8681f3b64cd9f552f3c63017905bc0445b5'), 'include/freetype/ftpfr.h': (420, 'abcd3880087350bf05ec23bebd70793dd63318c9'), 'include/freetype/ftrender.h': (420, '292c797cce587776c5c54b1a3dd1cfc9977765b2'), 'include/freetype/ftsizes.h': (420, 'f609eb2d76a705329d6ab1356f227a8766ae8536'), 'include/freetype/ftsnames.h': (420, 'f5511495f048cdb089bd9f5934e4d40754e4c6e8'), 'include/freetype/ftstroke.h': (420, 'c7f1d4643f04a2de62869e0061e02ea374f5045e'), 'include/freetype/ftsynth.h': (420, '90b4b19c25f88ba673eb6b6c739fb5b64e2adc72'), 'include/freetype/ftsystem.h': (420, '2ad3d7286dc776518cbd617fdba8fd3800dd6a6e'), 'include/freetype/fttrigon.h': (420, 'ebedc3a8d1ebb13c9377716104750727d4e17227'), 'include/freetype/fttypes.h': (420, '2f3ca05955a030fe20c9be6c7dd2b3d008635927'), 'include/freetype/ftwinfnt.h': (420, 'b95cad0a42209bf8de551e560f01a0ee11080dc1'), 'include/freetype/internal/autohint.h': (420, 'a22d8af7cd98b61d9aad6f59e08250b3dc3f35d5'), 'include/freetype/internal/cffotypes.h': (420, '8d6acbce7acbdb7911fa6bba086e061b0df9c220'), 'include/freetype/internal/cfftypes.h': (420, 'd474dcf40ea75cc8453e994a050e76af80961c91'), 'include/freetype/internal/compiler-macros.h': (420, '4863d6de75e89722595ce1ef35234f4788846332'), 'include/freetype/internal/ftcalc.h': (420, '129366f38949b07877e86d847c1520ed5da2d692'), 'include/freetype/internal/ftdebug.h': (420, '1baf5f385a8499a9cb304531567d68f09cf83e5f'), 'include/freetype/internal/ftdrv.h': (420, 'd52fc84f0fd926df3771388c1030dc9fe6c5d795'), 'include/freetype/internal/ftgloadr.h': (420, '902135e460cde79b973bbd3e3ff967b35dc6ebdd'), 'include/freetype/internal/fthash.h': (420, '642d21e21c6afb73b0d1bdd50c8a78c98af9810b'), 'include/freetype/internal/ftmemory.h': (420, 'ca840cb510be169caab470f94586e768cb653e34'), 'include/freetype/internal/ftmmtypes.h': (420, '854798ad3c0e87a391d3f626f0d4cbf73f7f3a0b'), 'include/freetype/internal/ftobjs.h': (420, 'f97262ffa95148629a076582db00dfaf6184a48a'), 'include/freetype/internal/ftpsprop.h': (420, '5967199a3bc9026967ec675b098311878c664e0b'), 'include/freetype/internal/ftrfork.h': (420, 'd0bb6b5bb0022019b5e8d21426363e4ec2acd886'), 'include/freetype/internal/ftserv.h': (420, '3b326627074d6eb214ccc9162742f2406601cdba'), 'include/freetype/internal/ftstream.h': (420, 'd60cd481c893fe7d3ff7c2b6fa5bf73b2e4f0a77'), 'include/freetype/internal/fttrace.h': (420, '22291ef7cfe5ead9ca7701524284b9711a0b1808'), 'include/freetype/internal/ftvalid.h': (420, 'fbcf2c63efafe8d7de217d86bc517bd226a61446'), 'include/freetype/internal/psaux.h': (420, 'ee574fef11b1ad9fba14ae561c97f7f8a7fe9dd4'), 'include/freetype/internal/pshints.h': (420, 'e7adcd380587d5139c6d8fd0c599b7380f959766'), 'include/freetype/internal/services/svbdf.h': (420, '52212cc7a2b8d7bee9241ceb42ce07e0bd1a5a2d'), 'include/freetype/internal/services/svcfftl.h': (420, 'ab29dede537e9d8833609baa25efd478e7722e53'), 'include/freetype/internal/services/svcid.h': (420, '9063211ee01773fc57a0103575627d9d4e389030'), 'include/freetype/internal/services/svfntfmt.h': (420, '91a6f007aa52cdec84644201d8f0cba1c2d8076d'), 'include/freetype/internal/services/svgldict.h': (420, '6020f9f78a6eb52d563b166e8bc9af4c2252f7de'), 'include/freetype/internal/services/svgxval.h': (420, '056114e6f8cc6f43448d0ff79ca07d85583e4b8f'), 'include/freetype/internal/services/svkern.h': (420, '7a06a01e8f019cc3a4fe2b0f97fa9605de9d3373'), 'include/freetype/internal/services/svmetric.h': (420, 'b6559d2b1ad33b2bbb368a65c3659791360aec0d'), 'include/freetype/internal/services/svmm.h': (420, 'fd851dba120f7c965bd06c7875d2d47b016de65c'), 'include/freetype/internal/services/svotval.h': (420, '487dca3f04353242a3fb5f8c204c6847621eba4b'), 'include/freetype/internal/services/svpfr.h': (420, '94cd695eb00f328004b124a31c014cf195663dba'), 'include/freetype/internal/services/svpostnm.h': (420, 'd99f4f681ef43085d5227aaee75a288638766435'), 'include/freetype/internal/services/svprop.h': (420, 'b6cba4c7f42bbf163d5969cf7b75bd54a17928e0'), 'include/freetype/internal/services/svpscmap.h': (420, '310eb53f33301ce15ebc5b5931ece4a9842c8e82'), 'include/freetype/internal/services/svpsinfo.h': (420, '78725a48fa5dab363e5d3daea2b84de821f6795b'), 'include/freetype/internal/services/svsfnt.h': (420, '0ce5aca13761a221386b0b2065440e425213c78c'), 'include/freetype/internal/services/svttcmap.h': (420, 'd7ad8066b5ee83a3a12ab36b7f243996cfc87a32'), 'include/freetype/internal/services/svtteng.h': (420, 'd4a9bab6ded8f429a3b893d029a5b3546304e9c9'), 'include/freetype/internal/services/svttglyf.h': (420, '528238024baa71292ce162ca4b3a5eb5db509038'), 'include/freetype/internal/services/svvarc.h': (420, '753340904d6674db40fc6e3ce7c3743d2c0eab7b'), 'include/freetype/internal/services/svwinfnt.h': (420, 'e5a3a6649b6fbbb684ba3d503bd6d26112f3fdf5'), 'include/freetype/internal/sfnt.h': (420, 'cc1ac7a6e4cf23561b8546f9efcd691eb770b924'), 'include/freetype/internal/svginterface.h': (420, '3a4ca314ddb2ea061e337b46f1ab9eb5657ffdd3'), 'include/freetype/internal/t1types.h': (420, 'e39076f19563198b060ff9a3f10fe0f91046f29e'), 'include/freetype/internal/tttypes.h': (420, 'ad45da39b994ac3365c831b3e3475c2dca9647ec'), 'include/freetype/internal/wofftypes.h': (420, 'b8ef95e27aada7a0295f73e688fca736f0a3a05b'), 'include/freetype/otsvg.h': (420, '42330a703b0285aad808f4121a7b321fc6092fe1'), 'include/freetype/t1tables.h': (420, 'badfdf40762dfafa1d9e86d5515498788cd5d550'), 'include/freetype/ttnameid.h': (420, '76ddb6f0a51ad5f3cb45b0b91873b33050b7e83e'), 'include/freetype/tttables.h': (420, 'a2ec304483a509926e28192e74bcd77856139b17'), 'include/freetype/tttags.h': (420, '7d431cea490bb24c23efd53af8253d314f280b26'), 'include/ft2build.h': (420, 'ffbf4a1e6ad1549b783c4351e42ca8d5ef014bb8'), 'meson.build': (420, 'fe26d30ff3444e625db0235eaa022b7a483c03e6'), 'meson_options.txt': (420, '67d0fa313371e84477eefc72a5dc4c730bac7b2b'), 'mkfile': (420, '2986bd12fdeae369c440b38533646c45b67bfcad'), 'modules.cfg': (420, 'b9b4718f187364e6657105320e220222d5bc0a2c'), 'objs/.gitignore': (420, 'f8476208f65968980ca4799e7cdfc074f7d36f1c'), 'objs/README': (420, 'befb63e049201f146e061849628e43c54f3eb21a'), 'src/autofit/afadjust.c': (420, '6940baf68cc3152c2f0a9f1cae66ea016b194b4c'), 'src/autofit/afadjust.h': (420, '85dbfaad29e0222792235c0f950853c09e73ce4d'), 'src/autofit/afblue.c': (420, '77c8389ec7fe60835777db2a7ba5d1990930c314'), 'src/autofit/afblue.cin': (420, '70b7e025214d4956f5ba3f8a5771b555c0b3c521'), 'src/autofit/afblue.dat': (420, 'e62754fc7e06db9ae97a03e01232579649e22595'), 'src/autofit/afblue.h': (420, 'f124eedee4d171f8ae10932e5b4c31f60ccdd3b4'), 'src/autofit/afblue.hin': (420, '931c5010606cf3233e5fe7ee91bfdd7c12a08049'), 'src/autofit/afcjk.c': (420, '7a1cc32c9d46d7e1d8734698f04815ca2b67f2c2'), 'src/autofit/afcjk.h': (420, '98681868a85e6f0c3bc97bd5ae30c7b4f60b6c2f'), 'src/autofit/afcover.h': (420, 'd60e0050bece2aa73b5fcfe7308a660029c1dcc5'), 'src/autofit/afdummy.c': (420, 'f9d1dd38dba42aae0a39414b9731bdf218ca7476'), 'src/autofit/afdummy.h': (420, '14546b1e50e2775593f959e20d4fe436833014f2'), 'src/autofit/aferrors.h': (420, '3d7538ba2d885381560279c205e0d25771df4d90'), 'src/autofit/afglobal.c': (420, 'ff6903cc174aa7fe271d7f04bfbc9066613c8576'), 'src/autofit/afglobal.h': (420, 'c4dd93358398a0474dde9500f6844e891b73fa60'), 'src/autofit/afgsub.c': (420, '4a9b9ef69faa21c29bb3290a3a3d129551e5de2a'), 'src/autofit/afgsub.h': (420, '10884f9236e09f72a4051200d7e4c46d3d567f7b'), 'src/autofit/afhints.c': (420, '376912a5d1217e288190b1f9291375a095d805ce'), 'src/autofit/afhints.h': (420, '84244d6f5c70be9349ab99bd3984df4becbdf2da'), 'src/autofit/afindic.c': (420, '29b6d22ed650ab8aaaf82797c7ffc3f622442340'), 'src/autofit/afindic.h': (420, 'df4892a9f1ce28759d4fba36d947152403c6c168'), 'src/autofit/aflatin.c': (420, '3c97f91dd933c99a08ae770455ffbe85659a23f7'), 'src/autofit/aflatin.h': (420, 'b6bdc5177f7f987b6fb4ba816cae4eb8a318add5'), 'src/autofit/afloader.c': (420, '8ac7b53856bcfef47fcf0985ca88cc70b3caf6ef'), 'src/autofit/afloader.h': (420, '8efd0fd57e9976cb0397ed6c686e867212d06b5b'), 'src/autofit/afmodule.c': (420, '57d5d47dfbda2ed2b999ac65c8a803e3c2d2f8f2'), 'src/autofit/afmodule.h': (420, '1f8a68122d3bcf121713a1398cb2060fb6eb7c4e'), 'src/autofit/afranges.c': (420, 'c9f5e0a8aab073f592462185a0e0c67bdc391922'), 'src/autofit/afranges.h': (420, 'f29369451286be69ad51d9cdaaa7f4bccc3a1a45'), 'src/autofit/afscript.h': (420, 'd071ed68b7e5a0f603e7fed288a92fee4ece7f48'), 'src/autofit/afshaper.c': (420, '3c0ffe09473547aa23881e885d2a9446d906af6a'), 'src/autofit/afshaper.h': (420, '6e73b9fb2ebdfa81d3a27cc5345c8a18127498a4'), 'src/autofit/afstyles.h': (420, 'e7a7fe531baac95f8c3c14b9215d47ffa92076f0'), 'src/autofit/aftypes.h': (420, 'a3a881eedeb0227391ad62a58025736ee6cde42b'), 'src/autofit/afws-decl.h': (420, 'ddebdcd1e785dcb799e54240429befa4dc205779'), 'src/autofit/afws-iter.h': (420, '720c2dc50c907529cf97b231821fef75baa9cd09'), 'src/autofit/autofit.c': (420, '8cd973bf147f28e452556645ffe7086d91693248'), 'src/autofit/ft-hb-decls.h': (420, '056b53a191d8edf493f33de8d8f73c7979fae256'), 'src/autofit/ft-hb-ft.c': (420, '05a66ad32f6790f7a5bc80a734df6452f599ef88'), 'src/autofit/ft-hb-ft.h': (420, 'f4f1d6291ff35d5dedc92a6163332ba77db77fae'), 'src/autofit/ft-hb-types.h': (420, '6176622f7caa58672a72737dc633366042cdd6c3'), 'src/autofit/ft-hb.c': (420, 'ed438da6afe62f7867e35cd3887d0df5e9a4d132'), 'src/autofit/ft-hb.h': (420, 'd2cc0482eb6b25c5b1ceb3592e118c0205a30770'), 'src/autofit/hb-script-list.h': (420, '1caa16aabe7f991579fc72ad178837fac3a525fe'), 'src/autofit/module.mk': (420, 'a82bedb9f2bd672bb3d864b8ab24784d0f7b2ec3'), 'src/autofit/rules.mk': (420, '9e39db33c90cc91aec7ec9a63463efe32022e3a6'), 'src/base/ftadvanc.c': (420, '6485834666624bac9dd9fc2e3085f21440ed19e6'), 'src/base/ftbase.c': (420, '5a5c8515982a1a39784f2c114a2abe6d183e309b'), 'src/base/ftbase.h': (420, '952ac51d503aac844a883898b2ec67749f185ccb'), 'src/base/ftbbox.c': (420, '4007a9314f085d83ad7843ed61df5ee1b4475e95'), 'src/base/ftbdf.c': (420, '7ce76d3c48446f67d00f0c996b4c7c437e9f45e2'), 'src/base/ftbitmap.c': (420, '1606cbfa09053b9a63b29e06da8aaef062ecd20b'), 'src/base/ftcalc.c': (420, 'c78d3b6da4b8f350bacbd356c27800d1e0845b76'), 'src/base/ftcid.c': (420, '878c666e12982584db1caabd901f49bd8c910ff0'), 'src/base/ftcolor.c': (420, 'ed6b5f0599fc08c85f155dc952a46fc4242a2ce8'), 'src/base/ftdbgmem.c': (420, '0335f142562a31eb662b5e333e7c2b7d482232b4'), 'src/base/ftdebug.c': (420, '27091a557984d45dd16b7fdba05af843601934e3'), 'src/base/fterrors.c': (420, 'a140dab860174bd46455715ac35992b36d796d44'), 'src/base/ftfntfmt.c': (420, '99e8c2b17dfe880f115c8411c34d8061a347e9eb'), 'src/base/ftfstype.c': (420, '58d5144a9e02a2893f72f91645ab468c147e11a9'), 'src/base/ftgasp.c': (420, '3c13456802e6823eceba9382b1ff009b9d9b3d54'), 'src/base/ftgloadr.c': (420, 'bd66e61d1c285fa1b68780d5dcacc005950e1b6e'), 'src/base/ftglyph.c': (420, '096f4d965e87268e614a0e505b45958fc3d1defa'), 'src/base/ftgxval.c': (420, 'e48f582c712a12f5b6dc3812507143e43e051cbd'), 'src/base/fthash.c': (420, 'ab248ace8bd01b3680767fb5b49d7e2ed46afbb4'), 'src/base/ftinit.c': (420, 'b20289316dc2ff3b6fb1a7f7e1def6e1d6392494'), 'src/base/ftlcdfil.c': (420, '9adbf7518f6060163c864f1bfac9b8909dd183e8'), 'src/base/ftmac.c': (420, '7251a4cb9621a74355425707195bcf7311360fdc'), 'src/base/ftmm.c': (420, '0d3bf3b77d847a2d1cab105a509ff2a3f402c50a'), 'src/base/ftobjs.c': (420, 'acefdf46fd9dbcf9134333e3777bccceaaf3f331'), 'src/base/ftotval.c': (420, 'ae14113612f6ab3d57918f6caaccf6018e4ecb6c'), 'src/base/ftoutln.c': (420, 'b37b53312fcd3d6f24dd22958ee82b77d0ac4b52'), 'src/base/ftpatent.c': (420, '3f149eb607fd52e3205d1d32350e5abec5294cd0'), 'src/base/ftpfr.c': (420, 'f95808201ab886b0de628d0fd1500e32d5b34a73'), 'src/base/ftpsprop.c': (420, '13f6c5102ccddfe7b22169925fc67517b74d5fad'), 'src/base/ftrfork.c': (420, 'fbb8ace7173a0fdbd61ff7221b6eae50633518b5'), 'src/base/ftsnames.c': (420, 'd8274cccd4063353a64e93d9af8f9b1808ec3c5d'), 'src/base/ftstream.c': (420, 'b08a1a9b6580545e66334423c4c6f226eec2bb47'), 'src/base/ftstroke.c': (420, 'cc93265b0ba210ca1435a3e2cbc647b2c6f82869'), 'src/base/ftsynth.c': (420, '23960eda3a96a1ebf524690160118fa9af896a01'), 'src/base/ftsystem.c': (420, 'be9159f6141ddb4e53efd019e5730f32da0c1dee'), 'src/base/fttrigon.c': (420, 'baa47eba08414b597e7ee5750b0b3f3f970c303d'), 'src/base/fttype1.c': (420, 'f9a46801f3ce30ae2139b9fe811fb74cd447237f'), 'src/base/ftutil.c': (420, '5d8fc7b9bf37f238c8cc461863040bf9bab8179c'), 'src/base/ftver.rc': (420, '9253f332cd443e3654690bd2bcefef816750725d'), 'src/base/ftwinfnt.c': (420, '038451ae0954bf5de202844912a6526e5fae46bf'), 'src/base/md5.c': (420, 'b235e17a56832cec9e3a7fccdf8c40149bc5aad8'), 'src/base/md5.h': (420, '2da44bf355a3a00b5abd283792e53efad339b1f3'), 'src/base/rules.mk': (420, 'e806066485f9df01e826e78cc7433622d9253945'), 'src/bdf/README': (420, 'd7cb8c14ef6d969fed46151803382c6ea9da7dd9'), 'src/bdf/bdf.c': (420, '249012e5907ed3d3cb9da2a8a081a54ed9aa119f'), 'src/bdf/bdf.h': (420, '85a9e4f2ec148e27d0fd396e11571126ae012b95'), 'src/bdf/bdfdrivr.c': (420, '94549b69224866e6c316c5f4d44bec67b609ad18'), 'src/bdf/bdfdrivr.h': (420, '54aaa3353cebcd1299213c65816dca48f368b6b0'), 'src/bdf/bdferror.h': (420, 'c1b54448714069d5ee4fb61a0caa963f69419c14'), 'src/bdf/bdflib.c': (420, 'ab6f6a9bf23c4ef771037fddc54932c8b560d884'), 'src/bdf/module.mk': (420, 'fe06ae8e0647446b8817a4f1d9ac6bd69a5b1fa0'), 'src/bdf/rules.mk': (420, 'd1dd76b1c3d8fcb77dd7d5b2f4d578875dd1f05a'), 'src/bzip2/ftbzip2.c': (420, '6326c71ac112bba1c574cca3002ffd8aff613087'), 'src/bzip2/rules.mk': (420, '3adf30653339ee27ca836cf476ece87b200682ae'), 'src/cache/ftcache.c': (420, '95f784370d1477492fd281e8c828f50e7e613e69'), 'src/cache/ftcbasic.c': (420, '81c5ded4737230502755fc3734739f3abe51279c'), 'src/cache/ftccache.c': (420, '28f3f3e7a0147b50f64bd8be00f4897b138f8f55'), 'src/cache/ftccache.h': (420, '55ecf5e70cb75202822fabbeaae8df2a182f31c7'), 'src/cache/ftccback.h': (420, 'f013833e66433dccc6159fbebe9a3abb469d6892'), 'src/cache/ftccmap.c': (420, '758468fb45939d1d37ba5c35a62d37c7a07dbd87'), 'src/cache/ftcerror.h': (420, '41491c2f46a08f15858e262a12c53e90987ce4b9'), 'src/cache/ftcglyph.c': (420, '3c291ce50fb8fa93b54fd7178d8df5ca69a588ca'), 'src/cache/ftcglyph.h': (420, '1777a17e53f83f201aadc98ba78ab5b52bea15c9'), 'src/cache/ftcimage.c': (420, 'b028bf8e45746e977fe662aaa286dc7ea9fa2aad'), 'src/cache/ftcimage.h': (420, 'd48c54c51b88f1996274cbaf6053f7bf0fc0929f'), 'src/cache/ftcmanag.c': (420, '4c1d85ab1f0f4ff9819092b560886b67ea726250'), 'src/cache/ftcmanag.h': (420, '22d56d7eb8477fe168bba27f2559a2b36757eb3d'), 'src/cache/ftcmru.c': (420, 'e8dc9052daa7b4ff5ff639a8743a215319f406c1'), 'src/cache/ftcmru.h': (420, '962d0886875d3ba5deaf8cdf0b4177eeec440fce'), 'src/cache/ftcsbits.c': (420, '7f6a9b1b4ed6db131c5d9429668011f21c252560'), 'src/cache/ftcsbits.h': (420, '669e77cb309c4adf47c8878275f7e61d90bc4264'), 'src/cache/rules.mk': (420, '6f56da94208c5434313bd77193976e7a014341bd'), 'src/cff/cff.c': (420, '8125c104d1f2089ad41eee62276e0bc6f16af7d8'), 'src/cff/cffcmap.c': (420, '75e2420d99e9ddedf41be113ff97c4d2425a1821'), 'src/cff/cffcmap.h': (420, 'e812e7a89e51d414318c28c48ad8da72140ce839'), 'src/cff/cffdrivr.c': (420, '935548ea647f55404d868fb7219238b624cb72dc'), 'src/cff/cffdrivr.h': (420, '2f3c58b67d77424823edc590334d40b8717a0682'), 'src/cff/cfferrs.h': (420, 'ca1158c0dfdc8aa927a46b136fb14ecbe04156db'), 'src/cff/cffgload.c': (420, '331c681b8ae2e4cd7ca28cfabe1a7756a7195c7a'), 'src/cff/cffgload.h': (420, 'eb4b5f30b5ea12caa838813820209427246a62ed'), 'src/cff/cffload.c': (420, 'cfd5317ff52a1522d3895ff27243cee1f669b2e1'), 'src/cff/cffload.h': (420, 'ab02ca2d7f640a0a7bfe33256c32f027e513c478'), 'src/cff/cffobjs.c': (420, '8efdd109f95cae0bb825400a70661348f61fd5aa'), 'src/cff/cffobjs.h': (420, 'c6ab805c5be98f2244ad5a36f41eb659e23a236e'), 'src/cff/cffparse.c': (420, 'fadc3258c9605216faadcb98a53dacc4c7b57fe6'), 'src/cff/cffparse.h': (420, '1daf548cbccabfe86bc7dee181b22dca5a4b235b'), 'src/cff/cfftoken.h': (420, '0eadc7118fb1bcfac1edf2c0fe5216b1d16b3416'), 'src/cff/module.mk': (420, '14dda50d6669652de04a22bbca962bb21a2a2e37'), 'src/cff/rules.mk': (420, 'f3a729db5ddccedb73d958ffa21803afbec5f900'), 'src/cid/ciderrs.h': (420, '00497b796b385ae47355dff9956621647ee7d199'), 'src/cid/cidgload.c': (420, 'cc68b4a96009ec533abb47172999407ee9db96fc'), 'src/cid/cidgload.h': (420, '51b16c75944b04dfddb619fa7cdc8f9adb1faa50'), 'src/cid/cidload.c': (420, '170ae2d1c7d22db2fb6423a4c938f621490c6df4'), 'src/cid/cidload.h': (420, 'cef7d1c9a6a184896188aa14ff0d912a9153e88f'), 'src/cid/cidobjs.c': (420, '2d11609598b8f167c5c647d7df788ebf45f97189'), 'src/cid/cidobjs.h': (420, '406646231278bd5d70e5a304cfb5a6f96bc241e8'), 'src/cid/cidparse.c': (420, 'fb936bd48d9a946e821259c43ebc7d512f9a9924'), 'src/cid/cidparse.h': (420, '555245230b92bdffe87b3d2a6eac3379622bf403'), 'src/cid/cidriver.c': (420, 'ab188776e2fd8a499b9d326817b6502042d53349'), 'src/cid/cidriver.h': (420, 'a4ddccec8082b7a108a0fb36c599f05029568038'), 'src/cid/cidtoken.h': (420, '22136310cdf7482b1e096b6244e6e062d55e5088'), 'src/cid/module.mk': (420, '2994e4777c15841743878d59788ae39eff138ac1'), 'src/cid/rules.mk': (420, '5569c7c5ebc97001529f701d25296425da48cca0'), 'src/cid/type1cid.c': (420, 'fbcce4f70bb271a364c8cdaa70623ec6c75f1b17'), 'src/dlg/dlgwrap.c': (420, '159af2d6751f2b51d7a8dc4a95c47834a62bf9f4'), 'src/dlg/rules.mk': (420, 'f575a8bd1e2d0a0c92dc7cc88058df26d110c7fa'), 'src/gxvalid/README': (420, '1bde33300e59a02dd7fe52c2b1a99164afe646e2'), 'src/gxvalid/gxvalid.c': (420, '93c10f127d6adac08f67f182480e1698fcea5767'), 'src/gxvalid/gxvalid.h': (420, 'ee76946147cee6f4e48ac935281b2b772fdb88e6'), 'src/gxvalid/gxvbsln.c': (420, '9b9c10b9805f6e026b398193b619b6f769c2376f'), 'src/gxvalid/gxvcommn.c': (420, '111db5c693de6353f2c36f08dc671df69d39e69e'), 'src/gxvalid/gxvcommn.h': (420, 'cc95c4cece1077b5133dd5790c3645fccaf92447'), 'src/gxvalid/gxverror.h': (420, '90a6eda03ece81d952f0aa688c8a822b09c6c494'), 'src/gxvalid/gxvfeat.c': (420, '826f3eedf5cbb435d814b253b8b32a92b58406cf'), 'src/gxvalid/gxvfeat.h': (420, '9d34b701a29512e683d3db573e1d0f4cfa6dcde1'), 'src/gxvalid/gxvfgen.c': (420, 'd0c53ca5261c252a41832fbdc744bfd33814a456'), 'src/gxvalid/gxvjust.c': (420, 'c5177522e3855e46d13cab9565f9c309ce69c772'), 'src/gxvalid/gxvkern.c': (420, 'f1f8ce7cd36515d7b64a52c6798f3ab4f3e0d555'), 'src/gxvalid/gxvlcar.c': (420, '7b90d43a7b3d50cafea766c0198c6bc28fd206cf'), 'src/gxvalid/gxvmod.c': (420, '89e142be5dcbd861b92555797ac2dd8608b9f537'), 'src/gxvalid/gxvmod.h': (420, '51e339e00be4205950de5b46548a4befd182a762'), 'src/gxvalid/gxvmort.c': (420, 'de03f2e3888518e56de6c8cdf727c3dd7ad978b9'), 'src/gxvalid/gxvmort.h': (420, '3db0d2a61e015062d3aac5bc5289435cc541bb43'), 'src/gxvalid/gxvmort0.c': (420, '78b042d5dedec1682ab6e5dfd2b2a72bc571861f'), 'src/gxvalid/gxvmort1.c': (420, '57ee197d4895c1bc847e3bef367fd487c90fb40b'), 'src/gxvalid/gxvmort2.c': (420, 'e982a67bf520e11af5a358c76c66b2ce23e56d73'), 'src/gxvalid/gxvmort4.c': (420, '2ad0632fa502085feb24bec1f1f549e19765e61d'), 'src/gxvalid/gxvmort5.c': (420, '613debd453750215f11d9e9fdc4b9c623dad51cd'), 'src/gxvalid/gxvmorx.c': (420, '9efe182038df1eeb55a89139e03d07a615e18f09'), 'src/gxvalid/gxvmorx.h': (420, '60b084a8d0b69ce42b6ec7c2c95d1950a482cd56'), 'src/gxvalid/gxvmorx0.c': (420, '54cded1f6465a1e86d8889a320b9342291b486e2'), 'src/gxvalid/gxvmorx1.c': (420, '56a64c257cf825b684ec03647ab6b81c0b7b9fe6'), 'src/gxvalid/gxvmorx2.c': (420, 'be333e0424bcaa83856a95a1db030ddbe9e0f746'), 'src/gxvalid/gxvmorx4.c': (420, '9af41f4bf505240f652f15e67432d11d9d712538'), 'src/gxvalid/gxvmorx5.c': (420, 'edc3f3bc01905f21bb5337ab0b9e69c554b6e323'), 'src/gxvalid/gxvopbd.c': (420, '265ad39a2ca2177eb76ab9e40291c34e3ca6de07'), 'src/gxvalid/gxvprop.c': (420, 'f27ce103c48be0af285996a67b50432b90f36243'), 'src/gxvalid/gxvtrak.c': (420, '06300beff342fc3fe19315d44311cd9fcb25cb68'), 'src/gxvalid/module.mk': (420, 'd6b58ee922e15aebaece85e9d65dad084b255294'), 'src/gxvalid/rules.mk': (420, '552f64dcc38afb98b8554a24ca25954e963bb356'), 'src/gzip/README.freetype': (420, '5d8b83d5dd783a68bb7382220009f5d3db96ff84'), 'src/gzip/adler32.c': (420, '260185b672f75eb6722fb633e29eadafbb750027'), 'src/gzip/crc32.c': (420, '6624c0ec5d0ab00ce209a0397eaedf213b4db6a1'), 'src/gzip/crc32.h': (420, '137df68d616c5ed38913579ba37b4e4c533fa903'), 'src/gzip/ftgzip.c': (420, '4a5ec87297402602e5f7dda10771726bd71eb688'), 'src/gzip/ftzconf.h': (420, '62adc8d8431f2f9149ae0b1583915e21a28dd8b5'), 'src/gzip/gzguts.h': (420, 'd7d733bda71b46c204930b73eebcec23ccf97476'), 'src/gzip/inffast.c': (420, '9354676e786ee7a6a31668adf9d25c712d57e657'), 'src/gzip/inffast.h': (420, 'a38c5be450ac4ca71891aa9fc3e062d7d332fba4'), 'src/gzip/inffixed.h': (420, 'd6283277694802ce7938f537f12990d6eead4924'), 'src/gzip/inflate.c': (420, 'c8125680b0c9440b6c639e54c96ec039515a3a2d'), 'src/gzip/inflate.h': (420, '8a0e437aea39470f66cd3afd07ac80060d05a23f'), 'src/gzip/inftrees.c': (420, '468eea8790a257c073771df5df572b1a4f301ff3'), 'src/gzip/inftrees.h': (420, 'd735b0a5145f3ba283754f50f352bd9732d754e3'), 'src/gzip/patches/freetype-zlib.diff': (420, '9c7e549c6e86e748110d9024e629c09079b9d219'), 'src/gzip/rules.mk': (420, 'baefc0b9bad85027ceb5341b447c145b47070497'), 'src/gzip/zlib.h': (420, 'fda054163ea593959cdfb074959cb3b89029920e'), 'src/gzip/zutil.c': (420, 'f76def425c7f701f6ac239923f2b39c89dfb4514'), 'src/gzip/zutil.h': (420, '2c96797e3ae73ff2c5a7809780ff891e021a7371'), 'src/hvf/hvf.c': (420, 'a0e0a58ce10a4d44e51cc67ad7b26ce77318bc64'), 'src/hvf/hvfdrv.c': (420, 'b59cb55c93f6cc8c39b9960344cd3ad1e30b1db1'), 'src/hvf/hvfdrv.h': (420, 'c27d7fcaa19753456ea0b18e639341a05be5b47e'), 'src/hvf/hvferror.h': (420, '6d474d292cf5762489897927c7afb562eca720e8'), 'src/hvf/hvfload.c': (420, 'a02d363c1da6fa8f4c2cf054cffa0ca914697f6a'), 'src/hvf/hvfload.h': (420, '0207a55e5ff05ce90bf96661eabb0309683def84'), 'src/hvf/hvfobjs.c': (420, '96536b8ef15b9989a4a22433f2c9310fbb64aca1'), 'src/hvf/hvfobjs.h': (420, 'ae9c90595e8122f2b9e152a8eaa987be506ff5b9'), 'src/hvf/module.mk': (420, 'b404119e881ca27b28d72d46f67d87511018e43e'), 'src/hvf/rules.mk': (420, '7083ecefb0b0a548bedfc58c416d41366d699f04'), 'src/lzw/ftlzw.c': (420, 'ce5070d75fa4ae6329f33b055a20e1d5eaf1dcbf'), 'src/lzw/ftzopen.c': (420, '3a42824902f425d04527e381ff814bef48b97413'), 'src/lzw/ftzopen.h': (420, '9c06b367d86a87d0925ed0a649eb2a1fa81ba72e'), 'src/lzw/rules.mk': (420, 'ec996bb918a262a2d17a68d308044803060d84ba'), 'src/otvalid/module.mk': (420, 'dadc349f3a74b5dfb85db9f7a4c75d0376832069'), 'src/otvalid/otvalid.c': (420, 'e68a0823fe7cca2b808e63e04f945a0443026593'), 'src/otvalid/otvalid.h': (420, '6ab7c65cb42475b79d09536b4c41c652c645111a'), 'src/otvalid/otvbase.c': (420, '8cea1319395ef6d94477196ab51773a3d7552222'), 'src/otvalid/otvcommn.c': (420, 'a6771c782658cf1a6b321d8d40bdd516733d8c96'), 'src/otvalid/otvcommn.h': (420, '4648e70dee2bbdc86586fcf01f7252dac430d380'), 'src/otvalid/otverror.h': (420, 'd1c2c4b56cf2d65fb87cab30680236aac287eb98'), 'src/otvalid/otvgdef.c': (420, '08d0a68d684b448d5a613d24835d2db6468c9b7e'), 'src/otvalid/otvgpos.c': (420, 'b9e36bd833b5ca97c75d086a9e1993ede27fcab1'), 'src/otvalid/otvgpos.h': (420, '8539801fd9388fbab90edfd47c2112615b67e662'), 'src/otvalid/otvgsub.c': (420, '2669be37c9fdbb97390481eea300cbbc79d690d2'), 'src/otvalid/otvjstf.c': (420, '6706e1a7f886486da8f94cd863a14525f03c3e6e'), 'src/otvalid/otvmath.c': (420, 'ccc4b89d296f40d205e1c6c41213bd569e75048d'), 'src/otvalid/otvmod.c': (420, '946c81902fd25bdedd256ab3074c58b58a0b6bf5'), 'src/otvalid/otvmod.h': (420, 'f00f98f12509507822be1c41bd1df1574d5f6535'), 'src/otvalid/rules.mk': (420, '83c426829d657b07f3d9b50b922cb296cfc6c43d'), 'src/pcf/README': (420, '09ea970edadb5247e7209e5e0a3d3d30c2a7210a'), 'src/pcf/module.mk': (420, 'df383ff0fbecd8f6b518f4c72fef9a7ee95b0450'), 'src/pcf/pcf.c': (420, '6b30fb249a709a0fe5d7cbba59bbd132f8f53983'), 'src/pcf/pcf.h': (420, '3134cc355b355e97e649ce39921aa653c860e19b'), 'src/pcf/pcfdrivr.c': (420, '11977c51edbe10b3759d2bfaaa348433a327121c'), 'src/pcf/pcfdrivr.h': (420, 'd4653937434bb896cfa350d3b2cbb4dd2e35c617'), 'src/pcf/pcferror.h': (420, '8b9e9902a36a1e823393c335053a9a5454b3cb5d'), 'src/pcf/pcfread.c': (420, '49d5171630d349e7444a420bb037e258b0649dba'), 'src/pcf/pcfread.h': (420, 'a54648fbf98e097908fb094c9367dacbce158264'), 'src/pcf/pcfutil.c': (420, 'cd26c77cadf2a00e4855c974eae84a41a96e99b2'), 'src/pcf/pcfutil.h': (420, 'a197c1559514a40cb278f2e9e2e981ba0e2813b9'), 'src/pcf/rules.mk': (420, '1b55daf4f43b245892a4f6c848e9292de6e6d063'), 'src/pfr/module.mk': (420, '9d57e36bb5d8ae0ae0de7fb7510e4903b6c36141'), 'src/pfr/pfr.c': (420, '260c2703cef7b67de64dcd5cdb481b9bfde94955'), 'src/pfr/pfrcmap.c': (420, '786aaa1163e59eca40f705591542d941c1ed8641'), 'src/pfr/pfrcmap.h': (420, '9ebb3f23daf01e00ac026c32c3f86baa44d69e2d'), 'src/pfr/pfrdrivr.c': (420, '31f3509bb7dbeaa10e2edcd1c81b5456457430bd'), 'src/pfr/pfrdrivr.h': (420, '2c75a14d78981e2660b0c4aae9f0053be7f61ad2'), 'src/pfr/pfrerror.h': (420, '78cbac32f88c83f0a3ee9d9ddcf1398c2f508c77'), 'src/pfr/pfrgload.c': (420, '68849b4a11315c204dd0b5f2c0d19e766705e083'), 'src/pfr/pfrgload.h': (420, '81a05327835832367eb99e96f0056744f68dcd43'), 'src/pfr/pfrload.c': (420, '1105ba4812bb5e43fc733c351f4133627d699705'), 'src/pfr/pfrload.h': (420, 'a2f3bcc3df92758c79d2a9c79890d3583c12a594'), 'src/pfr/pfrobjs.c': (420, 'bf538e20e54c533bff8e7673e32143a07e7772b0'), 'src/pfr/pfrobjs.h': (420, '3ad74e97d37b7d0beec0e05c5783f66ed1561a22'), 'src/pfr/pfrsbit.c': (420, '515089a65b6345315314903ae46018b052e09633'), 'src/pfr/pfrsbit.h': (420, '639f8c8182aee840927013e43c257975b12bd449'), 'src/pfr/pfrtypes.h': (420, '54cc09ca39560ce2e8ef7dc3a5bc464976558c6d'), 'src/pfr/rules.mk': (420, '842d88eac6066d792b1cf318eaf213091157b0f0'), 'src/psaux/afmparse.c': (420, '1cc8ab29d46a04b309ad71ff314e4cf253e8bfe1'), 'src/psaux/afmparse.h': (420, '02a9617b8dc4881b24ed328e5631e81409474922'), 'src/psaux/cffdecode.c': (420, '908a81126153418c61faecfd56a528f7daee8957'), 'src/psaux/cffdecode.h': (420, '0836a642b2ff2a67e6687c93b97e4b98b5934ecc'), 'src/psaux/module.mk': (420, '2c6ddacb96770c1b520c7aa3678d1b2d98f6fde0'), 'src/psaux/psarrst.c': (420, '70313d283a455ad7e9ec8667f9966c7934bfcbef'), 'src/psaux/psarrst.h': (420, '31e5330cc3808be6a5cc92f52a93cac2fb942035'), 'src/psaux/psaux.c': (420, 'f0c3c2ef97b5afa537e5930ffcbf167762e2b6ef'), 'src/psaux/psauxerr.h': (420, '5766482d1b708a7b0dc76518112f6673e20cea87'), 'src/psaux/psauxmod.c': (420, '2f9eb87484cb7f20431a945e795bbaf3f94aeec6'), 'src/psaux/psauxmod.h': (420, 'e7fa15c34b7979baa0f2011ac6edd36bce84eca4'), 'src/psaux/psblues.c': (420, '213b943b46576ddcca6b471cd5d3d0cf4d68acb0'), 'src/psaux/psblues.h': (420, '55fb88ecddfa1dc8a184a9e3d232b90ccfd16a91'), 'src/psaux/psconv.c': (420, '3a054cbbf6d885e8371f1d2a8966fc232d351bab'), 'src/psaux/psconv.h': (420, 'fc123faea4d775cdac45d675d6c4c51efb3e6a46'), 'src/psaux/pserror.c': (420, '98cebcf74d99ece4a36065894e6ace54cc8c9ead'), 'src/psaux/pserror.h': (420, '5738853face775a7944ebbf9c3e02958a93bd3a4'), 'src/psaux/psfixed.h': (420, '299d076370504844152c984f9c562a753139638a'), 'src/psaux/psfont.c': (420, '0db1f0c5bc460f5040e62c09295efd81cee08aca'), 'src/psaux/psfont.h': (420, '836fce4e4d32f6bca4cb695de49163ea8d4eb204'), 'src/psaux/psft.c': (420, 'fd0abe17154c71250566365ddce401c994288d5a'), 'src/psaux/psft.h': (420, 'd9082f3a2be120bd80edfaba983112a19324d91d'), 'src/psaux/psglue.h': (420, '63085d71cf50881c277808ea0980a31b19f0b0c2'), 'src/psaux/pshints.c': (420, '7bd08a9c9bf86af8d710c5566b305d6a0439847a'), 'src/psaux/pshints.h': (420, '31a8230364c3493199e3ca8fcf9cbaf6b14c4e86'), 'src/psaux/psintrp.c': (420, 'bb8efc8156feaffb42df1080b9283ddbe8e3411f'), 'src/psaux/psintrp.h': (420, 'd8b9342ecb61fd326b5f5e7d82fea5b3004cb321'), 'src/psaux/psobjs.c': (420, '5019f9925c1eb9644af70afe8165fb46fec781b5'), 'src/psaux/psobjs.h': (420, '04205f891b17194e2faac5ac76ded4da7571bb57'), 'src/psaux/psread.c': (420, '7f657f2cdc02da4bca7d02bf0aec05e9dab6830b'), 'src/psaux/psread.h': (420, '9e55fe044703042b55ef3371494cb204584adc12'), 'src/psaux/psstack.c': (420, '1360ba30dab7ef9827d62030e457a06fdea91cb9'), 'src/psaux/psstack.h': (420, '907b42400074ca510a37aa3230384d9e1659313b'), 'src/psaux/pstypes.h': (420, '435ef7e1fecff79263eabef658d215c193ee3f70'), 'src/psaux/rules.mk': (420, 'ace45afb4670a98e840091f22064d37393c6810e'), 'src/psaux/t1cmap.c': (420, '686ca7abdfa39210308797e279b83f3747fc1756'), 'src/psaux/t1cmap.h': (420, 'be66a0c7f6f4c31af8931867177793f36abd74f5'), 'src/psaux/t1decode.c': (420, 'ece512412da92fc1342883773181d62476b5a463'), 'src/psaux/t1decode.h': (420, '1b5d5205a865413e134136cd4e51b05d1130e0bd'), 'src/pshinter/module.mk': (420, '96aa535228a3dd3d6bb170ea6d86886cc1a9ec91'), 'src/pshinter/pshalgo.c': (420, 'f169fc3459df53ec5cda2c6f1e7d0f3c2833df3e'), 'src/pshinter/pshalgo.h': (420, '95d41b49aaf0ce857c426085dc47a8739ce18e71'), 'src/pshinter/pshglob.c': (420, '2e4efea068cec06553942064149229160db1ae7f'), 'src/pshinter/pshglob.h': (420, '0158b92ab9deba9e220354706b8af03e3df39f4a'), 'src/pshinter/pshinter.c': (420, 'f22de34bd4a126db749e26d36bd7074626faafbc'), 'src/pshinter/pshmod.c': (420, 'f6b2e2df94c0e44d2c5ce1e7c22ea3c9e08430fd'), 'src/pshinter/pshmod.h': (420, 'd68ef9a87369f7c23ed5e09987ecae209a6b0ee9'), 'src/pshinter/pshnterr.h': (420, '96bc3a31756f2af57021740100692c94008a9b53'), 'src/pshinter/pshrec.c': (420, 'f14c9c7cbda1ba5891f19a86b3784ce22ae8bcbd'), 'src/pshinter/pshrec.h': (420, '0b644f5b964488124923235c953b1d6560fe2463'), 'src/pshinter/rules.mk': (420, '7a3b8f5e33b817c2f5ea41f93610bc10aaf402d4'), 'src/psnames/module.mk': (420, 'bcda0067c820d7b42d32e125799a3a7f9a5990b5'), 'src/psnames/psmodule.c': (420, '5409c61fafab4845ede55fc2995d8db4a10d058d'), 'src/psnames/psmodule.h': (420, '7a619d83fb39b1614363da7d478f17fac9509fe3'), 'src/psnames/psnamerr.h': (420, 'bef9e797c8067446cf3e5db5ef9d56c40f6642bd'), 'src/psnames/psnames.c': (420, 'b0ade9874da6d9e5db3fa60c1a7f6b69298a4232'), 'src/psnames/pstables.h': (420, '8a32aac325f29aa765a39b53125689c8d07c6bb5'), 'src/psnames/rules.mk': (420, '7b0f1d6b47f42e7ceb1c4b3c59d0bbc33371fb1e'), 'src/raster/ftmisc.h': (420, 'cf96cd09ed5f1149ab5bc609a50f3ab8154f813d'), 'src/raster/ftraster.c': (420, 'e0121f6ee1acd0591dc292f3fcba364cec5d0028'), 'src/raster/ftraster.h': (420, 'e20184ddc8eaf4c72ce4b1e33372fdeb1c728b3d'), 'src/raster/ftrend1.c': (420, '6b28cb0bf8d8f4d12a3015859e1decd34ca86b6e'), 'src/raster/ftrend1.h': (420, '92249a0cb9f6c212f45f9b407f9a67a88a99076c'), 'src/raster/module.mk': (420, '7f7567c07ea0809714cb495bc498bf86a92490b0'), 'src/raster/raster.c': (420, 'df2ec38d42e890e8fb29d406be56f4614448ab1e'), 'src/raster/rasterrs.h': (420, '744d179cd8c2cec94be60496eb37162caaeb50bf'), 'src/raster/rules.mk': (420, '90af6d1852a8d4b6fa91b341221a68a88d77b0bb'), 'src/sdf/ftbsdf.c': (420, 'd70ebbf1732ac95f4f2fc95c7f466d931c9bf4c3'), 'src/sdf/ftsdf.c': (420, 'd9d43fcc41c1d487660d3d707d469a954bea5aeb'), 'src/sdf/ftsdf.h': (420, '9bf17d1d9116b0b3b7c612221520ae74877d4eb4'), 'src/sdf/ftsdfcommon.c': (420, 'ffbf7a46a4a300467afb2de82f80947c1620c631'), 'src/sdf/ftsdfcommon.h': (420, 'd62e00fa393cf311c50b1143ab652b6d0b981339'), 'src/sdf/ftsdferrs.h': (420, '5bb8f05bbe2ac3b3eef1e40560b8ce2b35eef9c4'), 'src/sdf/ftsdfrend.c': (420, '1f50ec447a27728fcd719978e3f57fa7aa07c676'), 'src/sdf/ftsdfrend.h': (420, 'bb362949af670f58d2541256dd64c386187222fc'), 'src/sdf/module.mk': (420, 'd8d0d49f6f998c440dba8d0292a0c2516c068624'), 'src/sdf/rules.mk': (420, '92ed750664f0499bf9519a054a313243d8b4a1b3'), 'src/sdf/sdf.c': (420, '21dfe6650b42afa466704893d688185096002a60'), 'src/sfnt/module.mk': (420, '5ed9ce0aa84c80a0a6487f2c5fe90b81f85bea2d'), 'src/sfnt/pngshim.c': (420, 'e588e6b380b449d5acd513a61a99bdcbde4eef54'), 'src/sfnt/pngshim.h': (420, 'f187b639a113431d8d4f602bde2479f7fba6d047'), 'src/sfnt/rules.mk': (420, '791d329a0941a55f6ce45bd7c45d86eb5480c138'), 'src/sfnt/sfdriver.c': (420, '4046b1a0cdbca7e32d4fbd1540d0c8858a73f8a2'), 'src/sfnt/sfdriver.h': (420, 'e9eed184b7fd52f7599bfbd3a55aeb6963fac33e'), 'src/sfnt/sferrors.h': (420, '05b259c1bfcb87397289867fc554de054b689714'), 'src/sfnt/sfnt.c': (420, '2eab87f2fd3a8c078dc3c2bf434ae40cdeb7a251'), 'src/sfnt/sfobjs.c': (420, 'b894331935a80e538345fcc9c7f36e49f6ef1a05'), 'src/sfnt/sfobjs.h': (420, 'a27ad7064acc5507cd696780db8a37cb034ce721'), 'src/sfnt/sfwoff.c': (420, '02125e3cba5d86d85107c8817a02c5d16dc62fbb'), 'src/sfnt/sfwoff.h': (420, 'a563fcc682aee14df26681191724c7ecb22e2b40'), 'src/sfnt/sfwoff2.c': (420, '013e30fc520baeb748f91f78bbc57ce5c144541f'), 'src/sfnt/sfwoff2.h': (420, 'e0296d82603e15afcf444368ab9e9001a26f0a5c'), 'src/sfnt/ttbdf.c': (420, 'e4ece461369177ff45a9bfcead110170a7141863'), 'src/sfnt/ttbdf.h': (420, '87d210e52f795093a85ae5ae311809f65b8d7a47'), 'src/sfnt/ttcmap.c': (420, '6fae7041b8ef6da32fdc8d28e996d3f84d59c1ab'), 'src/sfnt/ttcmap.h': (420, '4b8cbb3197a1cc338d597cabab9f5252cd9b6e30'), 'src/sfnt/ttcmapc.h': (420, 'a704690dae6fce800e7ab176da2048d9afbe3286'), 'src/sfnt/ttcolr.c': (420, '2272ec3739a236873cc3fe3a3cd89dc6fe9547b9'), 'src/sfnt/ttcolr.h': (420, 'c7bf1f2a4a78bbf9855158e19ceeb65b7a94fd92'), 'src/sfnt/ttcpal.c': (420, '04e2db1eab587195729a25254006fe024a6faa6c'), 'src/sfnt/ttcpal.h': (420, '5c2e660e13dc0099d19c87963e2d62b7408cf991'), 'src/sfnt/ttgpos.c': (420, '6f9bddf34ad2fddf4d7f765c2bf7e14a16096758'), 'src/sfnt/ttgpos.h': (420, '3c227445baca2a983376ec40c5e028abf6c6baf8'), 'src/sfnt/ttkern.c': (420, '65b249ff4cdb72e23c1d8d7c06b8f9f6293f86e6'), 'src/sfnt/ttkern.h': (420, '8cc912a79e53acf03c88a0175eecdb6aabce52f8'), 'src/sfnt/ttload.c': (420, '74d319e01f17690dd06f67fdf2cd0e94361a004a'), 'src/sfnt/ttload.h': (420, '0a0aab24ce6c0848d5ff39aca451ac37c683a79e'), 'src/sfnt/ttmtx.c': (420, 'e52df3f583e07825c796ca74901acb9a0c2acfe0'), 'src/sfnt/ttmtx.h': (420, '618e04ffd29d8ac820d6b22370b333efa96f856d'), 'src/sfnt/ttpost.c': (420, '0e0bd0fd366d5da967af5a9896187553bf3d3cc1'), 'src/sfnt/ttpost.h': (420, '896118015e1351d00eae462e2583180d3c9c022f'), 'src/sfnt/ttsbit.c': (420, 'd479b6a0b78ea0eb11676457db51c592a5b83aed'), 'src/sfnt/ttsbit.h': (420, '8fd45223264057600ce2c83fedc4f326476f630d'), 'src/sfnt/ttsvg.c': (420, '79cf531d054aee43fb42172f286b50e858470cb5'), 'src/sfnt/ttsvg.h': (420, '6253ed1d499494959515719a4f42c89b4016f6e9'), 'src/sfnt/woff2tags.c': (420, '1c3779d9f34cf1b4afc7c91e388f0bc273b1f47b'), 'src/sfnt/woff2tags.h': (420, '200262d38639f30f4bc5930a3ffacd9ef5967487'), 'src/smooth/ftgrays.c': (420, '69805f08a270e1c30a3d1616ccffb300b5e5fd52'), 'src/smooth/ftgrays.h': (420, '99c7383e76e82b400991d563dafe71f225ee34a4'), 'src/smooth/ftsmerrs.h': (420, '2f2276bd58c8e37a189b65dc5243a77a7c8e6794'), 'src/smooth/ftsmooth.c': (420, 'f5a3de65d801aa5be5b3de2f6835481c2462e691'), 'src/smooth/ftsmooth.h': (420, '56c7ac70b5c90f9391108ee3b08155fde1dbcff5'), 'src/smooth/module.mk': (420, 'f09f29423c85c469891275fe1890daf498105fbf'), 'src/smooth/rules.mk': (420, '1cdda6d8397682db7bccf116a04fdd8ec763e48d'), 'src/smooth/smooth.c': (420, '4ecd3ccdb9cf45b17c42abe43556716f5f60d302'), 'src/svg/ftsvg.c': (420, 'c98d7f7db90dd99fc8a6f2fa28f00e6b34dd92ef'), 'src/svg/ftsvg.h': (420, '6254485c5a50f4337725d203b2d8652f1fe6295c'), 'src/svg/module.mk': (420, '5a93e174367c9e2d50d7e5a36ff8fe3ee76ec775'), 'src/svg/rules.mk': (420, '53f4629f8cbf3bc5ba48dcea59c407e4295de478'), 'src/svg/svg.c': (420, 'fff03ee59e8a39083a641ae78bae24f776c6d938'), 'src/svg/svgtypes.h': (420, 'f731bdf111267511938ee0b27ac915388f005ffc'), 'src/tools/afblue.pl': (420, '24d01cd1ff5b9bbe4fc66193054c37c171096934'), 'src/tools/apinames.c': (420, '2aa4b9a215b161a332f5ce3be56c7edcc350a273'), 'src/tools/chktrcmp.py': (493, 'd072a87866cba70028fa37a018b2085ecf10ae39'), 'src/tools/cordic.py': (420, '6511429889744ab0ad823ef480c27a723b4ff25b'), 'src/tools/ftrandom/Makefile': (420, '24dc49c563961522b068c37a31bbb81bcf70eac1'), 'src/tools/ftrandom/README': (420, '7c610864b6adbf630677227bca5f5eb13214e6d0'), 'src/tools/ftrandom/ftrandom.c': (420, '0ee765e528face9ecd75c70944874f517c7def8f'), 'src/tools/glnames.py': (420, '9dc28dbc86154bb35f45c6f28134d0e20f463ba6'), 'src/tools/make_distribution_archives.py': (493, 'f29eb128c7a3585bf3846901a9cc6570a0508683'), 'src/tools/no-copyright': (420, 'e171b76f3a79d29d12b3d49c12d75cceb2179759'), 'src/tools/test_afm.c': (420, 'a4b2268984ece21c56a1a909b202024af5493655'), 'src/tools/test_bbox.c': (420, 'd9fd932993d152fcba10e3b615b1c66a2947ec6c'), 'src/tools/test_trig.c': (420, '4f3410ab388400e82a284bf02021a2d8115cdc2d'), 'src/tools/update-copyright': (493, '674823ceb21a2923fad5aa157a7b7f2de058eddd'), 'src/tools/update-copyright-year': (493, '2b19d01fa1fb5c97c7121c45998c5dc60206bef3'), 'src/tools/vms_shorten_symbol.c': (420, '81f2a71877fdeef7a0c7d3c1f8efbd314706f0b9'), 'src/truetype/module.mk': (420, 'e4627b669111e31c7e0cf6991fa0f8a3d08147c0'), 'src/truetype/rules.mk': (420, 'c8b5611b6ef2f0a6c1bd6ff10a4de97607e14dbc'), 'src/truetype/truetype.c': (420, '631f004cb3da3b1d35da9e719789060c752645e4'), 'src/truetype/ttdriver.c': (420, 'b9530b518bcd2bc7007a0b37e1a2c37a5d7ce484'), 'src/truetype/ttdriver.h': (420, 'c00bba066e30f8d84e24ffdef6761125a341793e'), 'src/truetype/tterrors.h': (420, '1ae4b087ac8ecbc5645f76242698a98018a13932'), 'src/truetype/ttgload.c': (420, 'f665361646dda40ec264e711a463758ab8cbd228'), 'src/truetype/ttgload.h': (420, '3d6a762d1f7fe29564b8cb8a1c5fc61ae50bd672'), 'src/truetype/ttgxvar.c': (420, 'd3f8c30fa06ccb88effa20ea2ffc534d182908c3'), 'src/truetype/ttgxvar.h': (420, 'c8446e134b2882ae6706f3ca71fc43cd4413f547'), 'src/truetype/ttinterp.c': (420, 'cc99b2ebd42ef5c98ffb068dc58cf9790e9cfe4d'), 'src/truetype/ttinterp.h': (420, '5b71bb82d8053e69c0c2e095a4727d80e00eb1f0'), 'src/truetype/ttobjs.c': (420, '8c76e23dbf812363b8a5e5d7bfbbe3d0bb212546'), 'src/truetype/ttobjs.h': (420, '01e581e1c1a1412debbaa5b5380e5398008d2e3b'), 'src/truetype/ttpload.c': (420, 'ec85f48ce2c2ebe0765094dc8d24ec20bedf0d18'), 'src/truetype/ttpload.h': (420, 'ad0a9eb7a6d5dc440e1274cd7a4eaf266ca39511'), 'src/truetype/ttvarc.c': (420, 'de57443ced65e5395d2f76643481824422c0e1bc'), 'src/truetype/ttvarc.h': (420, '1ac742a396208bdbabf269c30c6a35a25857e922'), 'src/type1/module.mk': (420, 'a0aeada3ebb29693ac3edac7e99bf0c0c2a4a03e'), 'src/type1/rules.mk': (420, '5d9c2e7e4f3460eb155bffe024daafb3ccf2cb67'), 'src/type1/t1afm.c': (420, 'cc94a0d4a4567f3e73bb95740fe03fa2eaa278cd'), 'src/type1/t1afm.h': (420, 'f31c9d100f0acb1e44e5fc1550ebfb35d74bbc2b'), 'src/type1/t1driver.c': (420, '1d7a342708dd78983a7ca1d67c84d5a9de2bcb95'), 'src/type1/t1driver.h': (420, '2869adab6e747e371177ade81a7c92b5618fbe61'), 'src/type1/t1errors.h': (420, 'efe53be1f4cdb4ccb8c705c03ce47d0d522d04be'), 'src/type1/t1gload.c': (420, 'dd9b6cd80fc2e2f6634dad71760a43f518ad8522'), 'src/type1/t1gload.h': (420, 'b3de427a2f3d283b094c6d44b63e9c450beec448'), 'src/type1/t1load.c': (420, '2ed327ba2e75b0ddd4e62597c4de0249ea17b6fe'), 'src/type1/t1load.h': (420, '39d4b94e9dc8ac8eede58a5a50e8ab47d05333ee'), 'src/type1/t1objs.c': (420, '4ee0a591096b6c79f65ff502e78121a4af147574'), 'src/type1/t1objs.h': (420, 'f152f630a86ec773cfb305d2505f9d92af10b249'), 'src/type1/t1parse.c': (420, '73bfb0cdecce6870f1192c344eea918544f05ab3'), 'src/type1/t1parse.h': (420, 'ebd7c3fb34047e7322bcc400cb4b292f9b408f54'), 'src/type1/t1tokens.h': (420, '745351a34c9540900be09df00e9fada02474d7bc'), 'src/type1/type1.c': (420, 'b8e88e6eac5ee1e3ac9f2e78a7c101d27d794fe6'), 'src/type42/module.mk': (420, 'd87f3a404e5d7bbb1d055198308b834a0e5270a5'), 'src/type42/rules.mk': (420, '3c796cee85f04e3ef757376f0d114568319d34ca'), 'src/type42/t42drivr.c': (420, 'a45d13ebd189f979a2e435d93863b9896b3f5b5c'), 'src/type42/t42drivr.h': (420, '1c2bb2029afe3d724da13b0ee945c4ddceda9016'), 'src/type42/t42error.h': (420, '9c386d8c48f8de240d3f3c95eafca1b8c55b3303'), 'src/type42/t42objs.c': (420, 'a01c3129d07b2fcc977c7323de578f624a193469'), 'src/type42/t42objs.h': (420, '15767f871634c2eb75010ef2f1005fcd347c758a'), 'src/type42/t42parse.c': (420, 'd645be2a01467142fdac8336d20e16e4801111db'), 'src/type42/t42parse.h': (420, '4e61169a8710868782cb565404c0e2d7e8d37051'), 'src/type42/t42types.h': (420, 'b0bf9e8ecfed4eeeb7d146fef858ad8a73fd000c'), 'src/type42/type42.c': (420, 'da1e6214d32bdbde951bee10e381c9f42c75c698'), 'src/winfonts/fnterrs.h': (420, 'b2644edbf3a35c99115724b8b6515660ffe5ab53'), 'src/winfonts/module.mk': (420, 'd49dc9d3b2ab93cdc3941dbb2cae466cdd76f8c5'), 'src/winfonts/rules.mk': (420, 'b65bb4c41af9ccd4a25e538a693c9e23c80aef49'), 'src/winfonts/winfnt.c': (420, '99f31f61f7b63389c8d4e9c61d5cbf4ea5fa56fa'), 'src/winfonts/winfnt.h': (420, '420e11e3c6709418c7a582bf59c423b29f888b7f'), 'subprojects/harfbuzz.wrap': (420, '3ef970046cb348c170d5346cda75faeaa81753cc'), 'subprojects/libpng.wrap': (420, '7bc11fc0fa9abf5fcbc6317b18bf18b888b14f3f'), 'subprojects/zlib.wrap': (420, '0626401ac2559b541b45ac90eb184ad0c2c6b10e'), 'tests/README.md': (420, '13d1e6cb8fb840c0420fcd744fb77373ec54fab7'), 'tests/data/varc-null-condition.ttf': (420, 'c68f5c922d4de32929b468a102159b60dfa6fd24'), 'tests/data/varc-reset-only.ttf': (420, '19cbb5bbf82e50437c4420f9ea2ec78d05e95153'), 'tests/data/varc-short-cff2.otf': (420, 'ffd46414a384406f7e67817cd9bb76eec5c92041'), 'tests/data/varc-static-cff2.otf': (420, '577396e9cf9c987098d9ca677b0bfa88b31130a9'), 'tests/data/varc-static-gvar.ttf': (420, '649c2961c766bfd92c2a32e17c5b9b66649ba51a'), 'tests/data/varc-value-conditions.ttf': (420, 'dcef465a6d1538c9f628fdf50c11bb7b4cde9780'), 'tests/data/varc-variation-store.ttf': (420, 'd403410e488ee365929033b310894dff96241e3a'), 'tests/issue-1063/main.c': (420, '3d59da7b4d49ef381ce383a0c0cdc7810ad942ee'), 'tests/issue-1441/README.md': (420, '74dafeaabe020c4663812bddda189b903e8e540f'), 'tests/issue-1441/main.c': (420, 'dd7e20b94780c407c534c2fc3b0890d9b16bf612'), 'tests/issue-1441/make-fonts.py': (420, 'd8ede9063f6fe5e95cc20a474093169f5bb1029f'), 'tests/issue-1469/README.md': (420, 'd9c013dbf2c7fa06e56fb5ead69d3a8708ecb492'), 'tests/issue-1469/main.c': (420, 'b67c023375d8922fd5910e23a860b300cb1039db'), 'tests/issue-1469/make-fonts.py': (420, 'e0bea4ed3406eceec937401a0e06d29546e6789e'), 'tests/meson.build': (420, '4448bb1e2ab01aeb20a8b62fbbc6100bd9e6584a'), 'tests/outline-reverse/main.c': (420, '8f292c6e5b4121c1d18cd828d0c7af9c2861f0d2'), 'tests/scripts/download-test-fonts.py': (493, '52b742e22ca616899adc32ddc3308906cb5a8c4d'), 'tests/varc/main.c': (420, '6981f498add1b8b4f443129128e54d4b24d8d5a7'), 'vms_make.com': (420, '75bcbd7abf51f95b15c96b55a4ca392d9aa8a2bc')}
FREETYPE_GIT_DIRS = frozenset(['builds', 'builds/amiga', 'builds/amiga/include', 'builds/amiga/include/config', 'builds/amiga/src', 'builds/amiga/src/base', 'builds/ansi', 'builds/atari', 'builds/beos', 'builds/cmake', 'builds/compiler', 'builds/dos', 'builds/mac', 'builds/meson', 'builds/os2', 'builds/plan9', 'builds/symbian', 'builds/unix', 'builds/vms', 'builds/wince', 'builds/wince/vc2005-ce', 'builds/wince/vc2008-ce', 'builds/windows', 'builds/windows/vc2010', 'builds/windows/visualc', 'builds/windows/visualce', 'devel', 'docs', 'docs/markdown', 'docs/markdown/images', 'docs/markdown/javascripts', 'docs/markdown/stylesheets', 'docs/oldlogs', 'include', 'include/freetype', 'include/freetype/config', 'include/freetype/internal', 'include/freetype/internal/services', 'objs', 'src', 'src/autofit', 'src/base', 'src/bdf', 'src/bzip2', 'src/cache', 'src/cff', 'src/cid', 'src/dlg', 'src/gxvalid', 'src/gzip', 'src/gzip/patches', 'src/hvf', 'src/lzw', 'src/otvalid', 'src/pcf', 'src/pfr', 'src/psaux', 'src/pshinter', 'src/psnames', 'src/raster', 'src/sdf', 'src/sfnt', 'src/smooth', 'src/svg', 'src/tools', 'src/tools/ftrandom', 'src/truetype', 'src/type1', 'src/type42', 'src/winfonts', 'subprojects', 'tests', 'tests/data', 'tests/issue-1063', 'tests/issue-1441', 'tests/issue-1469', 'tests/outline-reverse', 'tests/scripts', 'tests/varc', '', 'subprojects/dlg'])

SUBTITLE_CAPTURE_TAR_OUTPUT = "apple-subtitle-release-sources.tar"
SUBTITLE_CAPTURE_RECEIPT_OUTPUT = "apple-subtitle-release-sources.json"
SUBTITLE_BUILD_OUTPUT = "apple-subtitle-builds.json"
SUBTITLE_INSTALLED_HELPERS = {
    "Sources/BuildScripts/subtitle-release-sources.py":
        "d09496535e49241575093692846de60b9e5948819d6540c4002047d12b5d37f3",
}
SUBTITLE_MATRIX = CRYPTO_MATRIX
SUBTITLE_VERSIONS = {"libunibreak": "8.0", "libfribidi": "1.0.17",
                     "libharfbuzz": "15.0.0", "libbluray": "1.5.0"}
SUBTITLE_SELECTORS = {"libunibreak": "8.0-9c4fad6e",
                      "libfribidi": "1.0.17-6949dcde",
                      "libharfbuzz": "15.0.0-968536e9", "libbluray": "1.5.0-f676408e"}
SUBTITLE_ROUTES = {"libunibreak": "release-autoconf",
                   "libfribidi": "release-meson", "libharfbuzz": "release-meson", "libbluray": "release-meson"}
SUBTITLE_ARGUMENTS = {
    "libbluray": ("--wrap-mode=nodownload", "--force-fallback-for=libudfread",
                  "-Denable_docs=false", "-Denable_tools=false", "-Denable_devtools=false",
                  "-Denable_examples=false", "-Dbdj_jar=disabled", "-Dembed_udfread=true",
                  "-Dfontconfig=disabled", "-Dfreetype=enabled", "-Dlibxml2=enabled"),
    "libunibreak": None,
    "libfribidi": ("--wrap-mode=nodownload", "-Dtests=false", "-Ddocs=false",
                    "-Dbin=false", "-Ddeprecated=true"),
    "libharfbuzz": ("--wrap-mode=nodownload", "-Dauto_features=disabled",
                     "-Dtests=disabled", "-Ddocs=disabled", "-Dutilities=disabled",
                     "-Dintrospection=disabled", "-Dfreetype=disabled",
                     "-Dcoretext=disabled", "-Dglib=disabled", "-Dgobject=disabled",
                     "-Dcairo=disabled", "-Dchafa=disabled", "-Dpng=disabled",
                     "-Dzlib=disabled", "-Dicu=disabled", "-Dgraphite2=disabled",
                     "-Dfontations=disabled", "-Dharfrust=disabled", "-Dkbts=disabled",
                     "-Dwasm=disabled", "-Dgpu_demo=disabled", "-Dbenchmark=disabled",
                     "-Draster=disabled", "-Dvector=disabled", "-Dgpu=disabled",
                     "-Dsubset=disabled"),
}
SUBTITLE_MAKE_ARGUMENTS = ("-j1", "AUTOCONF=/usr/bin/false",
                           "AUTOHEADER=/usr/bin/false", "AUTOMAKE=/usr/bin/false",
                           "ACLOCAL=/usr/bin/false")
SUBTITLE_GENERATED = {
    "libbluray": ("crossFile.meson", "build.ninja", "compile_commands.json",
                  "meson-info/intro-buildoptions.json", "meson-info/intro-dependencies.json",
                  "config.h", "contrib/libudfread/config.h"),
    "libunibreak": ("Makefile", "config.status", "config.log"),
    "libfribidi": ("crossFile.meson", "build.ninja", "compile_commands.json",
                    "meson-info/intro-buildoptions.json",
                    "meson-info/intro-dependencies.json"),
    "libharfbuzz": ("crossFile.meson", "build.ninja", "compile_commands.json",
                     "meson-info/intro-buildoptions.json",
                     "meson-info/intro-dependencies.json"),
}
SUBTITLE_INSTALLED = {
    "libbluray": ("include/libbluray/bluray-version.h", "lib/pkgconfig/libbluray.pc"),
    "libunibreak": ("include/unibreakbase.h", "lib/pkgconfig/libunibreak.pc"),
    "libfribidi": ("include/fribidi/fribidi-config.h", "lib/pkgconfig/fribidi.pc"),
    "libharfbuzz": ("include/harfbuzz/hb-version.h", "lib/pkgconfig/harfbuzz.pc"),
}
SUBTITLE_TARGETS = {"libunibreak": "Libunibreak", "libfribidi": "Libfribidi",
                    "libharfbuzz": "Libharfbuzz", "libbluray": "Libbluray"}
SUBTITLE_LIBRARIES = (
    ("Libunibreak", "libunibreak", "libunibreak.a", "Libunibreak"),
    ("Libfribidi", "libfribidi", "libfribidi.a", "Libfribidi"),
    ("Libharfbuzz", "libharfbuzz", "libharfbuzz.a", "Libharfbuzz"),
    ("Libbluray", "libbluray", "libbluray.a", "Libbluray"),
)
SUBTITLE_HEADERS = {"libunibreak": "unibreakbase.h",
                    "libfribidi": "fribidi/fribidi-config.h",
                    "libharfbuzz": "harfbuzz/hb-version.h", "libbluray": "libbluray/bluray-version.h"}
SUBTITLE_VERSIONS['libfreetype'] = '2.15.0'
SUBTITLE_SELECTORS['libfreetype'] = '2.15.0-37515cf5'
SUBTITLE_ROUTES['libfreetype'] = 'release-meson'
SUBTITLE_ARGUMENTS['libfreetype'] = ('--wrap-mode=nodownload', '-Dzlib=system', '-Dharfbuzz=disabled', '-Dbzip2=disabled', '-Dmmap=disabled', '-Dpng=disabled', '-Dbrotli=disabled', '-Dhvf=disabled', '-Dtests=disabled', '-Derror_strings=false')
SUBTITLE_GENERATED['libfreetype'] = ('crossFile.meson', 'build.ninja', 'compile_commands.json', 'meson-info/intro-buildoptions.json', 'meson-info/intro-dependencies.json', 'ftoption.h', 'ftmodule.h', 'vortx-sdk-pkgconfig/zlib.pc')
SUBTITLE_INSTALLED['libfreetype'] = ('include/freetype2/freetype/freetype.h', 'include/freetype2/freetype/config/ftoption.h', 'include/freetype2/freetype/config/ftmodule.h', 'include/freetype2/freetype/config/ftconfig.h', 'lib/pkgconfig/freetype2.pc')
SUBTITLE_TARGETS['libfreetype'] = 'Libfreetype'
SUBTITLE_HEADERS['libfreetype'] = 'freetype2/freetype/freetype.h'
SUBTITLE_LIBRARIES = SUBTITLE_LIBRARIES + (('Libfreetype', 'libfreetype', 'libfreetype.a', 'Libfreetype'),)

SUBTITLE_MAX_RECORD = 16 * MIB
SUBTITLE_MAX_BODY = 8 * MIB
SUBTITLE_MAX_RECORD_BODIES = 8 * MIB
SUBTITLE_MAX_INLINE_RAW = 32 * MIB
SUBTITLE_MAX_RECEIPT = 64 * MIB
BLURAY_SOURCE_TRANSFORMS = {
    'meson.build': {
        'beforeSHA256': '5f707fc923e4d2b9c845adff896b7c1734ea257e4a5fe77c67ddc856caaf73a0',
        'afterSHA256': '97eab258bb691ded280ebeff128c5caf4f1807b3a78f76721bb30034d1c715cd',
        'replacements': [{'before': "    extra_dependencies += dependency('appleframeworks',\n        modules: ['CoreFoundation', 'DiskArbitration'])",
                          'after': "    extra_dependencies += dependency('appleframeworks', modules: ['CoreFoundation'])\n    if cc.get_define('TARGET_OS_OSX', prefix: '#include <TargetConditionals.h>') == '1'\n        extra_dependencies += dependency('appleframeworks', modules: ['DiskArbitration'])\n    endif"}]},
    'src/file/mount_darwin.c': {
        'beforeSHA256': '055d80dbbe5f4b64837347fce756d9538f6254ddbb7d5608cc26f1bb7caee4df',
        'afterSHA256': 'f439c23dd34529ad613909114e6dedd0f339550ba90b3ea243350333ab33c483',
        'replacements': [
            {'before': '#include <DiskArbitration/DADisk.h>', 'after': '#include <TargetConditionals.h>\n#if TARGET_OS_OSX\n#include <DiskArbitration/DADisk.h>\n#endif'},
            {'before': '    DASessionRef session = DASessionCreate(kCFAllocatorDefault);', 'after': '#if TARGET_OS_OSX\n    DASessionRef session = DASessionCreate(kCFAllocatorDefault);'},
            {'before': '    return result;\n}', 'after': '#endif\n    return result;\n}'}]},
    'src/libbluray/bdj/bdj.c': {
        'beforeSHA256': '5fbe6d6bde9ac48a89399553d1cd1bcbfd7cffbcbc6f88aa6f010e91f1307e1f',
        'afterSHA256': 'a5111e63b6b557820f395cbcd140d070c5181187b07ddf9fe5085fd0f33f78aa',
        'replacements': [
            {'before': '#include <unistd.h>\n#endif', 'after': '#include <unistd.h>\n#include <TargetConditionals.h>\n#endif'},
            {'before': 'static char *_java_home_macos()\n{', 'after': 'static char *_java_home_macos()\n{\n#if TARGET_OS_OSX'},
            {'before': '    return result;\n}\n#undef MACOS_JAVA_HOME', 'after': '    return result;\n#else\n    // Match the retained Apple wrapper: mobile targets cannot launch java_home.\n    return NULL;\n#endif\n}\n#undef MACOS_JAVA_HOME'}]},
}


def bluray_source_body(pin, name, body):
    if pin['id'] != 'libbluray' or name not in BLURAY_SOURCE_TRANSFORMS:
        return body
    if pin.get('sourceTransformPolicy') != 'bluray150-retained-apple-mobile-v1':
        raise ValueError('libbluray source transform policy differs')
    policy = BLURAY_SOURCE_TRANSFORMS[name]
    if hashlib.sha256(body).hexdigest() != policy['beforeSHA256']:
        raise ValueError('libbluray source transform preimage differs')
    for edit in policy['replacements']:
        before, after = edit['before'].encode(), edit['after'].encode()
        if body.count(before) != 1:
            raise ValueError('libbluray source transform anchor is not unique')
        body = body.replace(before, after)
    if hashlib.sha256(body).hexdigest() != policy['afterSHA256']:
        raise ValueError('libbluray source transform afterimage differs')
    return body



CREATED_MPV = {"player/owned_subtitle.c": READER_MPV["player/owned_subtitle.c"],
               "player/owned_subtitle.h": READER_MPV["player/owned_subtitle.h"],
               "player/reference_owned.inc": READER_MPV["player/reference_owned.inc"],
               "demux/reference_reader.c": READER_MPV["demux/reference_reader.c"],
               "demux/reference_reader.h": READER_MPV["demux/reference_reader.h"],
               "demux/reference_reader_internal.h": READER_MPV["demux/reference_reader_internal.h"],
               "stream/vortx_reference_reader_stream.h": READER_MPV["stream/vortx_reference_reader_stream.h"],
               "demux/reference_mkv.h": READER_MPV["demux/reference_mkv.h"],
               "demux/reference_mkv_reader.c": READER_MPV["demux/reference_mkv_reader.c"],
               "demux/reference_mkv_sparse.h": READER_MPV["demux/reference_mkv_sparse.h"],
               "demux/reference_mkv_sparse_planner.c": READER_MPV["demux/reference_mkv_sparse_planner.c"],
               "demux/reference_mkv_sparse_planner.h": READER_MPV["demux/reference_mkv_sparse_planner.h"],
               "demux/reference_mkv_sparse_worker.c": READER_MPV["demux/reference_mkv_sparse_worker.c"],
               "stream/vortx_reference_sparse.h": READER_MPV["stream/vortx_reference_sparse.h"],
               "sub/owned_text_slot.h": READER_MPV["sub/owned_text_slot.h"],
               "stream/reference_source.h": CANCEL["stream/reference_source.h"],
               "stream/vortx_http_request.h": "d7730cc3492f6eaf6f6f1134fa50331c13e251fb1ddab8e577e1b912b8679dc9"}
PATCH_COPIES = [
    ("0004-moltenvk-context-check-events-resize.patch", None, "mpv-moltenvk-resize.patch"),
    ("0005-coreaudio-hotplug-lifecycle.patch", None, "mpv-coreaudio-hotplug-lifecycle.patch"),
    ("0006-http-seek-interrupt.patch", "0001-http-seek-interrupt.patch", "mpv-http-seek-interrupt.patch"),
    ("0007-upstream-audio-layout-bounds.patch", "0002-upstream-audio-layout-bounds.patch", "mpv-upstream-audio-layout-bounds.patch"),
    ("0008-upstream-gpu-next-seek-reset.patch", "0003-upstream-gpu-next-seek-reset.patch", "mpv-upstream-gpu-next-seek-reset.patch"),
    ("0009-original-local-file-witness.patch", "0004-original-local-file-witness.patch", "mpv-original-local-file-witness.patch"),
    ("0010-upstream-edition-title-lifetime.patch", "0005-upstream-edition-title-lifetime.patch", "mpv-upstream-edition-title-lifetime.patch"),
    ("0011-owned-subtitle-constructor.patch", "0006-owned-subtitle-constructor.patch", "mpv-owned-subtitle-constructor.patch"),
    ("0012-owned-subtitle-publication.patch", "0007-owned-subtitle-publication.patch", "mpv-owned-subtitle-publication.patch"),
    ("0013-original-http-reference-recipe.patch", "0008-original-http-reference-recipe.patch", "mpv-original-http-reference-recipe.patch"),
    ("0014-original-http-cancel-lifetime.patch", "0009-original-http-cancel-lifetime.patch", "mpv-original-http-cancel-lifetime.patch"),
    ("0015-completed-response-observation.patch", "0010-completed-response-observation.patch", "mpv-completed-response-observation.patch"),
    ("0016-sent-request-evidence.patch", "0011-sent-request-evidence.patch", "mpv-sent-request-evidence.patch"),
    ("0017-bounded-prefix-request.patch", "0012-bounded-prefix-request.patch", "mpv-bounded-prefix-request.patch"),
    ("0018-original-transport-evidence.patch", "0013-original-transport-evidence.patch", "mpv-original-transport-evidence.patch"),
    ("0019-finite-reference-reader.patch", "0014-finite-reference-reader.patch", "mpv-finite-reference-reader.patch")]


def untracked(lane, row, recipe):
    if row["commit"] == WRAPPER[lane]:
        prefix = "Sources/BuildScripts/patch/libmpv/" if lane == "apple" else "buildscripts/patches/mpv/"
        result = {prefix + (apple if lane == "apple" else android): recipe["scripts/" + source]
                  for apple, android, source in PATCH_COPIES if lane == "apple" or android is not None}
        response_path = ("Sources/BuildScripts/patch/FFmpeg/0001-response-witness.patch" if lane == "apple"
                         else "buildscripts/patches/ffmpeg/0002-response-witness.patch")
        result[response_path] = recipe["scripts/ffmpeg-response-witness.patch"]
        generation_path = ("Sources/BuildScripts/patch/FFmpeg/0002-response-generation.patch" if lane == "apple"
                           else "buildscripts/patches/ffmpeg/0003-response-generation.patch")
        result[generation_path] = recipe["scripts/ffmpeg-response-generation.patch"]
        sent_path = ("Sources/BuildScripts/patch/FFmpeg/0003-sent-request-evidence.patch" if lane == "apple"
                     else "buildscripts/patches/ffmpeg/0004-sent-request-evidence.patch")
        result[sent_path] = recipe["scripts/ffmpeg-sent-request-evidence.patch"]
        transport_path = ("Sources/BuildScripts/patch/FFmpeg/0004-original-transport-evidence.patch" if lane == "apple"
                          else "buildscripts/patches/ffmpeg/0005-original-transport-evidence.patch")
        result[transport_path] = recipe["scripts/ffmpeg-original-transport-evidence.patch"]
        reader_path = ("Sources/BuildScripts/patch/FFmpeg/0005-finite-reference-reader.patch" if lane == "apple"
                       else "buildscripts/patches/ffmpeg/0006-finite-reference-reader.patch")
        result[reader_path] = recipe["scripts/ffmpeg-finite-reference-reader.patch"]
        if lane == "apple":
            result.update(CRYPTO_INSTALLED_HELPERS)
            result.update(SUBTITLE_INSTALLED_HELPERS)
            result.update(DOVI_INSTALLED_HELPERS)
            result.update(PLACEBO_INSTALLED_HELPERS)
        if lane == "android":
            result["buildscripts/patches/ffmpeg/0001-emudhra-spki-distrust.patch"] = recipe["scripts/native-media-hosted/android/buildscripts/patches/ffmpeg/0001-emudhra-spki-distrust.patch"]
            for helper in ("download-lua.sh", "download-libunibreak.sh"):
                name = "buildscripts/include/" + helper
                result[name] = recipe["scripts/native-media-hosted/android/" + name]
        return result
    if row["commit"] == PINS["mpv"]:
        result = dict(CREATED_MPV)
        if lane == "apple":
            result["video/out/vulkan/context_moltenvk.m"] = "00d2842ddb0dca5070feaf890c0190a0fe62beef9b29ec36e94e329d29a3da5e"
        return result
    if row["commit"] == PINS["ffmpeg"]:
        result = dict(READER_FFMPEG_CREATED, **{"libavformat/vortx_http_request.h":
                      "d7730cc3492f6eaf6f6f1134fa50331c13e251fb1ddab8e577e1b912b8679dc9"})
        if lane == "android":
            result["libavformat/tls_mbedtls_vortx_distrust.h"] = "376bd507b67b3b912443bda657465204b808518ea353d161e23e47e9b64c0bf4"
        return result
    return {}


def require_response_source(files, lane):
    # Verified native tar bytes must correspond to the exact tracked HTTP composition.
    need(lane in MBEDTLS, "Known transport-evidence source lane")
    expected = dict(RESPONSE, **{"libavformat/tls_mbedtls.c": MBEDTLS[lane]})
    for name, checksum in expected.items():
        row = files.get(name, {})
        need(row.get("kind") == "file" and row.get("tracked") is True and row.get("sha256") == checksum,
             "Response-witness afterimage: " + name)
    for name, checksum in READER_FFMPEG_CREATED.items():
        row = files.get(name, {})
        need(row.get("kind") == "file" and row.get("tracked") is False and row.get("sha256") == checksum,
             "Finite-reader private source: " + name)


def need(ok, message):
    if not ok:
        raise ValueError(message)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def digest(value):
    need(isinstance(value, str) and re.fullmatch(r"[0-9a-f]{64}", value), "Invalid SHA256")
    return value


def integer(value, limit):
    need(type(value) is int and 0 <= value <= limit, "Invalid integer/bound")
    return value


def keys(value, expected):
    need(type(value) is dict and set(value) == set(expected.split()), "Unexpected object keys")


def exact_equal(left, right):
    """JSON equality that never aliases booleans with integers."""
    if type(left) is not type(right):
        return False
    if isinstance(left, dict):
        return (set(left) == set(right) and
                all(exact_equal(left[key], right[key]) for key in left))
    if isinstance(left, list):
        return (len(left) == len(right) and
                all(exact_equal(a, b) for a, b in zip(left, right)))
    return left == right


def name_key(value):
    return unicodedata.normalize("NFC", value).casefold()


def safe_text(value):
    need(isinstance(value, str) and value.isprintable() and 0 < len(value.encode("utf-8")) <= 4096,
         "Invalid printable UTF-8 path/target byte bound")
    need(not any(c in "\\:\u2044\u2215\u29f8\u29f5\u2216" or (c != "/" and any(
         separator in unicodedata.normalize("NFKC", c) for separator in "/\\:")) for c in value), "Ambiguous path separator")


def path(value):
    safe_text(value)
    need(not value.startswith("/") and not any(unicodedata.normalize("NFKC", p).casefold()
         in {"", ".", "..", ".git"} for p in value.split("/")), "Unsafe archive path")
    return value


def link(name, target):
    safe_text(target)
    need(not target.startswith("/"), "Unsafe symlink target")
    parts = name.split("/")[:-1]
    for piece in target.split("/"):
        if piece == "..":
            need(len(parts) > 1, "Symlink escapes its source/package root")
            parts.pop()
        elif piece not in {"", "."}:
            need(unicodedata.normalize("NFKC", piece).casefold() not in {".", "..", ".git"}, "Ambiguous symlink component/Git metadata")
            parts.append(piece)


def measure(stream, limit, sink=None):
    h, count = hashlib.sha256(), 0
    for block in iter(lambda: stream.read(CHUNK), b""):
        count += len(block)
        need(count <= limit, "Inflated byte bound")
        h.update(block)
        if sink is not None:
            sink.write(block)
    return {"bytes": count, "sha256": h.hexdigest()}


def load(data):
    need(len(data) <= 32 * MIB, "JSON byte bound")
    def unique(pairs):
        result = {}
        for key, value in pairs:
            need(key not in result, "Duplicate JSON key")
            result[key] = value
        return result
    return json.loads(data, object_pairs_hook=unique, parse_constant=lambda _: need(False, "Nonfinite JSON"))


def read(archive, name, limit=32 * MIB):
    try:
        info = archive.getinfo(name)
    except KeyError as error:
        raise ValueError("Required ZIP member missing: " + name) from error
    need(info.file_size <= limit, "Member read bound: " + name)
    with archive.open(name) as stream:
        data = stream.read(limit + 1)
    need(len(data) <= limit, "Member read bound")
    return data


def zip_open(stream, count=100000):
    # Bound the central directory BEFORE ZipFile allocates/decodes its entries.
    stream.seek(0, 2)
    end = stream.tell()
    stream.seek(max(0, end - 65557))
    tail = stream.read(65557)
    offset = tail.rfind(b"PK\x05\x06")
    need(offset >= 0 and len(tail) - offset >= 22, "ZIP end record")
    record, position = tail[offset:], end - len(tail) + offset
    number = lambda data, a, b: int.from_bytes(data[a:b], "little")
    need(len(record) == 22 + number(record, 20, 22) and not any(record[4:8]), "ZIP comment/multidisk")
    entries, size, start, directory_end = number(record, 10, 12), number(record, 12, 16), number(record, 16, 20), position
    need(number(record, 8, 10) == entries, "ZIP split entry count")
    if entries == 65535 or size == 0xffffffff or start == 0xffffffff:
        stream.seek(position - 20)
        locator = stream.read(20)
        need(locator[:4] == b"PK\x06\x07" and not any(locator[4:8]) and number(locator, 16, 20) == 1, "ZIP64 locator")
        directory_end = number(locator, 8, 16)
        need(directory_end == position - 76, "ZIP64 contiguous end record")
        stream.seek(directory_end)
        record64 = stream.read(56)
        need(len(record64) == 56 and record64[:4] == b"PK\x06\x06" and number(record64, 4, 12) == 44 and not any(record64[16:24]), "ZIP64 end record")
        entries, size, start = number(record64, 32, 40), number(record64, 40, 48), number(record64, 48, 56)
        need(number(record64, 24, 32) == entries, "ZIP64 split entry count")
    need(entries <= count and size <= min(64 * MIB, count * 8192 + 22) and start + size == directory_end, "ZIP central-directory bound")
    stream.seek(0)
    result = zipfile.ZipFile(stream)
    if len(result.infolist()) != entries:
        result.close()
        raise ValueError("ZIP central-directory count")
    return result


def zip_index(archive, count=100000, total=4 * 1024**3, flat=False):
    rows, names, directories, size = {}, set(), set(), 0
    need(len(archive.infolist()) <= count, "ZIP entry bound")
    for info in archive.infolist():
        name = path(info.filename[:-1] if info.is_dir() else info.filename)
        need(name_key(name) not in names and not info.flag_bits & 1, "ZIP collision/encryption")
        names.add(name_key(name))
        size += info.file_size
        need(size <= total and info.file_size <= (4 * 1024**3 if flat else 512 * MIB)
             and (not flat or not info.is_dir()), "ZIP size/type bound")
        mode = info.external_attr >> 16
        need(not mode or stat.S_IFMT(mode) in {0, stat.S_IFREG, stat.S_IFDIR, stat.S_IFLNK}, "ZIP special file")
        need(stat.S_IFMT(mode) != stat.S_IFDIR or info.is_dir(), "ZIP directory shape")
        need(not flat or stat.S_IFMT(mode) in {0, stat.S_IFREG}, "CI ZIP external file type")
        if info.is_dir():
            directories.add(name)
        if not info.is_dir():
            kind = "symlink" if stat.S_ISLNK(mode) else "file"
            need(not flat or ("/" not in name and kind == "file"), "CI ZIP must contain flat files")
            with archive.open(info) as stream:
                row = measure(stream, 4 * 1024**3 if flat else 512 * MIB)
            row.update(kind=kind, mode=stat.S_IMODE(mode) or 0o644)
            if kind == "symlink":
                row["target"] = read(archive, info.filename, 4096).decode("utf-8")
                link(name, row["target"])
            rows[name] = row
    safe_ancestors(rows, directories)
    return rows


def safe_ancestors(rows, directories=()):
    folded = {name_key(name): row for name, row in rows.items()}
    for name in set(rows) | set(directories):
        pieces = name.split("/")
        need(not any(name_key("/".join(pieces[:i])) in folded for i in range(1, len(pieces))), "File/symlink ancestor")
    for name, row in rows.items():
        if row["kind"] != "symlink":
            continue
        todo, resolved, followed = deque(name.split("/")), [], 0
        while todo:
            piece = todo.popleft()
            if piece in {"", "."}:
                continue
            if piece == "..":
                need(len(resolved) > 1, "Symlink graph escapes component root")
                resolved.pop()
                continue
            resolved.append(piece)
            candidate = folded.get(name_key("/".join(resolved)))
            if candidate and candidate["kind"] == "symlink":
                followed += 1
                need(followed <= 40, "Cyclic/excessive source symlink graph")
                resolved.pop()
                todo.extendleft(reversed(candidate["target"].split("/")))


class BoundedReader:
    def __init__(self, stream, limit):
        self.stream, self.left = stream, limit

    def read(self, size=-1):
        data = self.stream.read(min(size if size >= 0 else self.left + 1, self.left + 1))
        self.left -= len(data)
        need(self.left >= 0, "Inflated tar byte bound")
        return data


class BoundedTarInfo(tarfile.TarInfo):
    def _proc_member(self, source):
        if self.type in {tarfile.XHDTYPE, tarfile.XGLTYPE, tarfile.GNUTYPE_LONGNAME, tarfile.GNUTYPE_LONGLINK}:
            need(self.size <= 16384, "Tar extended-header byte bound")
        need(self.type != tarfile.GNUTYPE_SPARSE, "Sparse tar member")
        return super()._proc_member(source)


def tar_index(archive, name, *, compressed=True, file_limit=64 * MIB, total=2 * 1024**3, capture=(), allow_dirs=False):
    rows, seen, directories, captured, size = {}, set(), set(), {}, 0
    with archive.open(name) as incoming:
        with gzip.GzipFile(fileobj=incoming) if compressed else incoming as decoded:
            limited = BoundedReader(decoded, total + 128 * MIB)
            with tarfile.open(fileobj=limited, mode="r|", bufsize=512, tarinfo=BoundedTarInfo) as source:
                for n, member in enumerate(source, 1):
                    item = path(member.name[:-1] if member.isdir() and member.name.endswith("/") else member.name)
                    need(n <= 100000 and name_key(item) not in seen, "Tar entry bound/collision")
                    seen.add(name_key(item))
                    need(member.mode in {0o644, 0o755, 0o777} and member.sparse is None and
                         set(member.pax_headers) <= {"path", "linkpath", "mtime", "atime", "ctime"}, "Tar mode/PAX metadata")
                    need(member.isfile() or member.issym() or member.isdir(), "Tar special/hardlink entry")
                    if member.isdir():
                        need(allow_dirs and member.size == 0, "Unrecorded source directory")
                        directories.add(item)
                        continue
                    if member.issym():
                        link(item, member.linkname)
                        data = member.linkname.encode("utf-8")
                        need(member.size == 0, "Symlink has payload")
                        row = {"bytes": len(data), "sha256": sha(data), "target": member.linkname, "kind": "symlink"}
                    else:
                        size += member.size
                        need(member.size <= file_limit and size <= total, "Tar regular byte bound")
                        sink = io.BytesIO() if item in capture else None
                        with source.extractfile(member) as stream:
                            row = measure(stream, file_limit, sink)
                        need(row["bytes"] == member.size, "Truncated tar file")
                        if sink is not None:
                            captured[item] = sink.getvalue()
                        row["kind"] = "file"
                    row["mode"] = member.mode
                    rows[item] = row
            # Consume the complete decoded stream; only zero tar padding is admitted.
            for block in iter(lambda: limited.read(CHUNK), b""):
                need(not block.strip(b"\0"), "Nonzero trailing tar data")
    safe_ancestors(rows, directories)
    return rows, captured


def crypto_canonical(value):
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()


def crypto_member_path(value):
    need(isinstance(value, str) and value and len(value.encode("utf-8")) <= CRYPTO_MAX_PATH and
         value.isprintable() and not value.startswith("/") and "\\" not in value and
         ":" not in value and "\x00" not in value,
         "Unsafe crypto source archive path")
    parts = value.rstrip("/").split("/")
    need(all(part not in ("", ".", "..") and part.casefold() != ".git" for part in parts),
         "Unsafe crypto source archive path component")
    return "/".join(parts)


def crypto_link_path(parent, target):
    need(isinstance(target, str) and target and len(target.encode("utf-8")) <= CRYPTO_MAX_PATH and
         target.isprintable() and not target.startswith("/") and "\\" not in target and
         ":" not in target and "\x00" not in target,
         "Unsafe crypto source symlink target")
    parts = list(parent)
    for part in target.split("/"):
        if part in ("", "."):
            continue
        if part == "..":
            need(parts, "Crypto source symlink escapes its release root")
            parts.pop()
        elif part.casefold() == ".git":
            need(False, "Crypto source symlink points through Git metadata")
        else:
            parts.append(part)
    return "/".join(parts)


def crypto_mtime(value):
    need(type(value) is int and 0 <= value <= CRYPTO_MAX_MTIME,
         "Crypto source mtime must be bounded integral seconds")
    return value


def crypto_archive_mtime_ns(member):
    """Recover exact archive nanoseconds without trusting TarInfo's float view."""
    need(type(member.pax_headers) is dict,
         "Subtitle source PAX metadata must be a dictionary")
    if "mtime" in member.pax_headers:
        raw = member.pax_headers["mtime"]
        need(type(raw) is str and len(raw) <= 32 and
             re.fullmatch(r"[0-9]{1,10}(?:\.[0-9]{1,9})?", raw) is not None,
             "Subtitle source PAX mtime must be bounded decimal text")
        seconds, separator, fraction = raw.partition(".")
        value = int(seconds) * 1000000000
        if separator:
            value += int(fraction.ljust(9, "0"))
    else:
        need(type(member.mtime) is int,
             "Subtitle source float-only mtime is not admitted")
        value = member.mtime * 1000000000
    need(type(value) is int and 0 <= value <= CRYPTO_MAX_MTIME_NS,
         "Subtitle source mtimeNs must be bounded integral nanoseconds")
    return value


def crypto_member_mtime(member, nanoseconds):
    return crypto_archive_mtime_ns(member) if nanoseconds else crypto_mtime(member.mtime)


def crypto_tar_stream(blob, compression):
    raw = io.BytesIO(blob)
    if compression == "xz":
        decoded = lzma.LZMAFile(raw, "rb")
    elif compression == "gz":
        decoded = gzip.GzipFile(fileobj=raw, mode="rb")
    elif compression == "none":
        decoded = raw
    else:
        need(False, "Unknown fixed crypto source compression")
    return tarfile.open(fileobj=BoundedReader(decoded, CRYPTO_MAX_UNCOMPRESSED), mode="r|")


def crypto_file_row(member, stream, nanoseconds=False):
    need(0 <= member.size <= CRYPTO_MAX_MEMBER, "Crypto source member exceeds its bound")
    hasher, count = hashlib.sha256(), 0
    while True:
        block = stream.read(min(CHUNK, member.size - count + 1))
        if not block:
            break
        count += len(block)
        need(count <= member.size, "Crypto source member exceeds its declared length")
        hasher.update(block)
    need(count == member.size, "Truncated crypto source member")
    return {"kind": "file", "mode": 0o755 if member.mode & 0o111 else 0o644,
            ("mtimeNs" if nanoseconds else "mtime"):
                crypto_member_mtime(member, nanoseconds),
            "bytes": count, "sha256": hasher.hexdigest()}


def crypto_finish_index(entries, nanoseconds=False):
    time_key = "mtimeNs" if nanoseconds else "mtime"
    for name in list(entries):
        parts = name.split("/") if name else []
        for end in range(1, len(parts)):
            parent = "/".join(parts[:end])
            row = entries.setdefault(parent, {"kind": "directory", "mode": 0o755,
                                               time_key: 0})
            need(row["kind"] == "directory", "Crypto source non-directory member has children")
            need(len(entries) <= CRYPTO_MAX_MEMBERS, "Crypto source archive has too many paths")
    folded = {}
    for name in entries:
        key = name.casefold()
        need(key not in folded or folded[key] == name,
             "Crypto source archive has case-colliding members")
        folded[key] = name

    def resolve(name, visited=()):
        need(len(visited) < 32, "Crypto source symlink chain exceeds its bound")
        parts = name.split("/") if name else []
        for end in range(1, len(parts) + 1):
            prefix = "/".join(parts[:end])
            row = entries.get(prefix)
            need(row is not None, "Dangling crypto source symlink")
            if row["kind"] == "symlink":
                need(prefix not in visited, "Cyclic crypto source symlink")
                destination = crypto_link_path(parts[:end - 1], row["target"])
                following = "/".join(([destination] if destination else []) + parts[end:])
                return resolve(following, visited + (prefix,))
            need(end == len(parts) or row["kind"] == "directory",
                 "Crypto source symlink resolves through a non-directory")
        return name

    for name, row in entries.items():
        if row["kind"] == "symlink":
            resolve(name)
    return [{"path": name, **entries[name]} for name in sorted(entries)]



def freetype_source_row(member, incoming, name):
    need(name in FREETYPE_GIT_FILES and 0 <= member.size <= CRYPTO_MAX_MEMBER, 'FreeType declared source Git blob')
    data = incoming.read(CRYPTO_MAX_MEMBER + 1)
    wanted_mode, wanted_oid = FREETYPE_GIT_FILES[name]
    mode = 493 if member.mode & 73 else 420
    need(len(data) == member.size and mode == wanted_mode, 'FreeType source Git length/executable mode')
    object_body = b'blob ' + str(len(data)).encode('ascii') + bytes([0]) + data
    need(hashlib.sha1(object_body).hexdigest() == wanted_oid, 'FreeType source official Git blob identity')
    return {'kind': 'file', 'mode': mode, 'mtimeNs': crypto_archive_mtime_ns(member), 'bytes': len(data), 'sha256': sha(data)}


def freetype_source_members(rows):
    observed = {r['path']: r for r in rows}
    need({p for p,r in observed.items() if r['kind'] == 'file'} == set(FREETYPE_GIT_FILES), 'FreeType exact775regular source blobs')
    for name, row in observed.items():
        need(row['kind'] in {'file','directory'}, 'FreeType source links/special files forbidden')
        need(row['kind'] != 'directory' or name in FREETYPE_GIT_DIRS, 'FreeType declared source directory')
        need(not name.startswith('subprojects/dlg/'), 'FreeType unused dlg gitlink stays empty')

def crypto_index_archive(pin, blob, nanoseconds=False):
    maximum_archive = min(CRYPTO_MAX_UNCOMPRESSED,
                          pin.get("maximumBytes", CRYPTO_MAX_ARCHIVE))
    need(len(blob) <= maximum_archive and
         (pin["bytes"] is None or len(blob) == pin["bytes"]) and
         sha(blob) == pin["sha256"],
         "Crypto release source body differs from its fixed pin")
    time_key = "mtimeNs" if nanoseconds else "mtime"
    entries = {"": {"kind": "directory", "mode": 0o755, time_key: 0}}
    seen, total, transformed = set(), 0, set()
    with crypto_tar_stream(blob, pin["compression"]) as archive:
        for member in archive:
            need(len(seen) < CRYPTO_MAX_MEMBERS, "Crypto source archive has too many members")
            full = crypto_member_path(member.name)
            root, separator, name = full.partition("/")
            need(root == pin["archiveRoot"], "Crypto source archive has a foreign top-level root")
            need(full.casefold() not in seen, "Duplicate or case-colliding crypto source member")
            seen.add(full.casefold())
            need(not getattr(member, "sparse", None) and
                 not any("sparse" in key.casefold() for key in member.pax_headers),
                 "Sparse crypto source members are not admitted")
            if not separator:
                need(member.isdir(), "Crypto source archive root is not a directory")
                entries[""][time_key] = crypto_member_mtime(member, nanoseconds)
                continue
            if member.isdir():
                row = {"kind": "directory", "mode": 0o755,
                       time_key: crypto_member_mtime(member, nanoseconds)}
            elif member.isreg():
                total += member.size
                need(total <= CRYPTO_MAX_UNCOMPRESSED, "Crypto source member total exceeds its bound")
                body = archive.extractfile(member)
                need(body is not None, "Missing crypto source member body")
                with body:
                    if pin['id'] == 'libfreetype':
                        row = freetype_source_row(member, body, name)
                    elif pin['id'] == 'libbluray' and name in BLURAY_SOURCE_TRANSFORMS:
                        raw = body.read(CRYPTO_MAX_MEMBER + 1)
                        need(len(raw) == member.size and len(raw) <= CRYPTO_MAX_MEMBER,
                             'Libbluray raw source member length differs')
                        data = bluray_source_body(pin, name, raw)
                        transformed.add(name)
                        row = {'kind': 'file', 'mode': 0o755 if member.mode & 0o111 else 0o644,
                               time_key: crypto_member_mtime(member, nanoseconds),
                               'bytes': len(data), 'sha256': sha(data)}
                    else:
                        row = crypto_file_row(member, body, nanoseconds)
            elif member.issym():
                crypto_link_path(name.split("/")[:-1], member.linkname)
                body = member.linkname.encode("utf-8")
                row = {"kind": "symlink", "mode": 0o777, "bytes": len(body),
                       time_key: crypto_member_mtime(member, nanoseconds), "sha256": sha(body),
                       "target": member.linkname}
            else:
                need(False, "Crypto source hardlinks and special members are not admitted")
            need(name not in entries, "Duplicate crypto source member")
            entries[name] = row
    need(pin['id'] != 'libbluray' or transformed == set(BLURAY_SOURCE_TRANSFORMS),
         'Libbluray fixed source transform members are incomplete')
    rows = crypto_finish_index(entries, nanoseconds)
    if pin["id"] == "libfreetype":
        freetype_source_members(rows)
    entry_point = pin.get("entryPoint", "configure")
    entry = next((row for row in rows if row["path"] == entry_point), None)
    need(entry is not None and entry["kind"] == "file" and
         (entry_point != "configure" or entry["mode"] == 0o755),
         "Release archive lacks its fixed regular build entry point")
    return rows


def crypto_expected_receipt(verified, profile=None,
                            identity_basis="fixed-sha256-corroborated-by-package-maintainer-metadata",
                            schema=1):
    if profile is None:
        profile = CRYPTO_SOURCE_PROFILE
    roots = []
    for pin, blob, rows in verified:
        roots.append({"id": pin["id"], "version": pin["version"], "url": pin["url"],
                      "archive": "archives/" + pin["filename"],
                      "archiveRoot": pin["archiveRoot"], "archiveBytes": len(blob),
                      "archiveSHA256": pin["sha256"],
                      "sourceRoot": "dist/" + pin["sourceRoot"],
                      "membersSHA256": sha(crypto_canonical(rows)), "members": rows,
                      **({'sourceTransformPolicy': pin.get('sourceTransformPolicy', 'none')} if schema == 3 else {})})
    return {"schema": schema, "profile": profile,
            "identityBasis": identity_basis,
            "upstreamSignatureVerified": False, "roots": roots}


def crypto_load(data):
    need(len(data) <= CRYPTO_MAX_RECEIPT, "Crypto JSON byte bound")
    def unique(pairs):
        result = {}
        for key, value in pairs:
            need(key not in result, "Duplicate crypto JSON key")
            result[key] = value
        return result
    return json.loads(data.decode("utf-8", errors="strict"), object_pairs_hook=unique,
                      parse_constant=lambda _: need(False, "Nonfinite crypto JSON"))


def crypto_capture_correspondence(blob, expected, member_limit=None,
                                  nanoseconds=False):
    if member_limit is None:
        member_limit = CRYPTO_MAX_MEMBERS * len(CRYPTO_SOURCE_OUTPUTS)
    need(0 < len(blob) <= CRYPTO_MAX_UNCOMPRESSED,
         "Captured crypto source tar exceeds its bound")
    observed, folded, count = set(), set(), 0
    with tarfile.open(fileobj=BoundedReader(io.BytesIO(blob), CRYPTO_MAX_UNCOMPRESSED), mode="r|") as archive:
        for member in archive:
            name = crypto_member_path(member.name)
            count += 1
            need(count <= member_limit and
                 name not in observed and name.casefold() not in folded and name in expected,
                 "Captured crypto source tar has an extra or duplicate member")
            observed.add(name)
            folded.add(name.casefold())
            wanted = expected[name]
            time_key = "mtimeNs" if nanoseconds else "mtime"
            if member.isdir():
                actual = {"kind": "directory", "mode": member.mode,
                          time_key: crypto_member_mtime(member, nanoseconds)}
            elif (member.isreg() and member.mode in (0o644, 0o755)
                  and not getattr(member, "sparse", None)
                  and not any("sparse" in key.casefold() for key in member.pax_headers)):
                body = archive.extractfile(member)
                need(body is not None, "Captured crypto source member has no body")
                with body:
                    actual = crypto_file_row(member, body, nanoseconds)
            elif member.issym():
                crypto_link_path(name.split("/")[:-1], member.linkname)
                body = member.linkname.encode("utf-8")
                actual = {"kind": "symlink", "mode": 0o777, "bytes": len(body),
                          time_key: crypto_member_mtime(member, nanoseconds), "sha256": sha(body),
                          "target": member.linkname}
            else:
                need(False, "Captured crypto source tar has an unsupported member")
            need(exact_equal(actual, wanted),
                 "Captured crypto source member differs from its raw archive")
    need(observed == set(expected), "Captured crypto source tar omitted release members")


def crypto_source_outputs(archive, *, pins=None, profile=None,
                          capture_tar=None, capture_receipt=None,
                          capture_tar_logical="crypto-release-sources.tar",
                          capture_receipt_logical="crypto-release-sources.json",
                          identity_basis="fixed-sha256-corroborated-by-package-maintainer-metadata",
                          receipt_schema=1, nanoseconds=False):
    if pins is None:
        pins = CRYPTO_SOURCE_OUTPUTS
    if profile is None:
        profile = CRYPTO_SOURCE_PROFILE
    if capture_tar is None:
        capture_tar = CRYPTO_CAPTURE_TAR_OUTPUT
    if capture_receipt is None:
        capture_receipt = CRYPTO_CAPTURE_RECEIPT_OUTPUT
    verified, output_rows = [], []
    for pin in pins:
        maximum = min(CRYPTO_MAX_UNCOMPRESSED,
                      pin.get("maximumBytes", CRYPTO_MAX_ARCHIVE))
        body = read(archive, pin["output"], maximum)
        rows = crypto_index_archive(pin, body, nanoseconds)
        verified.append((pin, body, rows))
        output_rows.append({"logicalPath": "archives/" + pin["filename"],
                            "name": pin["output"], "bytes": len(body), "sha256": sha(body)})
    expected_receipt = crypto_expected_receipt(
        verified, profile, identity_basis, receipt_schema)
    receipt_body = read(archive, capture_receipt, CRYPTO_MAX_RECEIPT)
    need(exact_equal(crypto_load(receipt_body), expected_receipt) and
         receipt_body == crypto_canonical(expected_receipt),
         "Captured crypto source receipt differs from raw source bodies")
    expected_members = {}
    for pin, _, rows in verified:
        for row in rows:
            name = pin["archiveRoot"] + (("/" + row["path"]) if row["path"] else "")
            need(name not in expected_members, "Overlapping captured crypto source roots")
            expected_members[name] = {key: value for key, value in row.items() if key != "path"}
    capture_body = read(archive, capture_tar, CRYPTO_MAX_UNCOMPRESSED)
    crypto_capture_correspondence(
        capture_body, expected_members, CRYPTO_MAX_MEMBERS * len(pins), nanoseconds)
    roots = []
    for root, output_row in zip(expected_receipt["roots"], output_rows, strict=True):
        roots.append({"id": root["id"], "version": root["version"],
                      "archiveRoot": root["archiveRoot"], "sourceRoot": root["sourceRoot"],
                      "archive": output_row, "membersSHA256": root["membersSHA256"],
                      **({'sourceTransformPolicy': root['sourceTransformPolicy']} if receipt_schema == 3 else {})})
    return {"profile": profile, "roots": roots,
            "capture": {
                "tar": {"logicalPath": capture_tar_logical,
                        "name": capture_tar, "bytes": len(capture_body),
                        "sha256": sha(capture_body)},
                "receipt": {"logicalPath": capture_receipt_logical,
                            "name": capture_receipt, "bytes": len(receipt_body),
                            "sha256": sha(receipt_body)}}}


def subtitle_source_outputs(archive):
    return crypto_source_outputs(
        archive, pins=SUBTITLE_SOURCE_OUTPUTS, profile=SUBTITLE_SOURCE_PROFILE,
        capture_tar=SUBTITLE_CAPTURE_TAR_OUTPUT,
        capture_receipt=SUBTITLE_CAPTURE_RECEIPT_OUTPUT,
        capture_tar_logical="subtitle-release-sources.tar",
        capture_receipt_logical="subtitle-release-sources.json",
        identity_basis="fixed-sha256-from-upstream-release-metadata-maintained-android-pin-or-official-sidecar; fixed-apple-source-transforms; official-freetype-git-membership-empty-dlg-v1",
        receipt_schema=3, nanoseconds=True)


def declared(rows, root, native=False):
    need(type(rows) is list and len(rows) <= 100000, "File inventory bound")
    result = {}
    for row in rows:
        keys(row, "path kind mode bytes sha256" + (" target" if row.get("kind") == "symlink" else "") + (" tracked" if native else ""))
        need(not native or type(row["tracked"]) is bool, "Native tracked classification")
        name = root + "/" + path(row["path"])
        need(name not in result and row["kind"] in {"file", "symlink"}, "File inventory identity")
        need(type(row["mode"]) is int and row["mode"] in ({511} if row["kind"] == "symlink" else {420, 493}), "File mode")
        integer(row["bytes"], 64 * MIB)
        digest(row["sha256"])
        result[name] = {key: value for key, value in row.items() if key not in {"path", "tracked"}}
    return result


def git_blob(repo, commit, name):
    env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
    env.update(GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_SYSTEM=os.devnull, GIT_CONFIG_NOSYSTEM="1",
               GIT_NO_REPLACE_OBJECTS="1", GIT_NO_LAZY_FETCH="1", GIT_OPTIONAL_LOCKS="0", GIT_TERMINAL_PROMPT="0", LC_ALL="C")
    def run(*args):
        value = subprocess.run([str(GIT), "-C", str(repo), *args], env=env, capture_output=True, timeout=20)
        need(value.returncode == 0 and len(value.stdout) <= 4 * MIB, "Pinned local Git read failed")
        return value.stdout
    entry = run("ls-tree", "-z", commit, "--", name).decode().rstrip("\0")
    need(entry.count("\t") == 1, "Ambiguous pinned producer path")
    identity, found = entry.split("\t")
    mode, kind, oid = identity.split()
    need(found == name and kind == "blob" and mode in {"100644", "100755"}, "Pinned producer identity")
    size = run("cat-file", "-s", oid).strip()
    need(size.isdigit() and int(size) <= 4 * MIB, "Pinned Git blob byte bound")
    data = run("cat-file", "blob", oid)
    need(len(data) == int(size), "Pinned Git blob size")
    return {"bytes": len(data), "sha256": sha(data), "kind": "file", "mode": int(mode[-3:], 8)}


SENT_FFMPEG_FUNCTIONS = frozenset(("avpriv_vortx_http_copy_sent_request_v2", "avpriv_vortx_http_sent_request_clear_v2"))
REFERENCE_FFMPEG_FUNCTIONS = frozenset((
    "avpriv_vortx_reference_capture_v1", "avpriv_vortx_reference_revalidate_v1",
    "avpriv_vortx_reference_recipe_current", "avpriv_vortx_reference_open_prefix_v1",
    "avpriv_vortx_reference_read_v1", "avpriv_vortx_reference_stats_v1",
    "avpriv_vortx_reference_reader_close_v1", "avpriv_vortx_reference_recipe_release_v1",
    "avpriv_vortx_reference_sparse_budget_create_v1",
    "avpriv_vortx_reference_sparse_budget_info_v1",
    "avpriv_vortx_reference_sparse_open_v1",
    "avpriv_vortx_reference_sparse_next_part_v1",
    "avpriv_vortx_reference_sparse_read_part_v1",
    "avpriv_vortx_reference_sparse_stats_v1",
    "avpriv_vortx_reference_sparse_close_v1",
    "avpriv_vortx_reference_sparse_budget_release_v1"))
PRIVATE_MPV_FUNCTIONS = frozenset(("stream_reference_sent_request_copy_transport",))


def dynamic_bridge_abi(value, records, validator_sha256, functions, schema, retired_v1):
    """Validate producer inspection metadata against already byte-bound JNI rows.

    This offline consumer does not execute an inspector or independently certify ELF.
    """
    keys(value, "schema reader libraries" + (" retiredV1Absent" if retired_v1 else ""))
    need(type(value["schema"]) is int and value["schema"] == schema and
         (not retired_v1 or value["retiredV1Absent"] is True), "Exact dynamic bridge ABI schema")
    reader = value["reader"]
    keys(reader, "mode requestedReader resolvedReader readerSHA256 readerVersion validatorSHA256")
    need(reader["mode"] in {"hosted-ndk-reader", "explicit-read-only-inspector"}, "Sent-request reader mode")
    for key in ("requestedReader", "resolvedReader"):
        name = reader[key]
        need(type(name) is str and 0 < len(name) <= 4096 and "\0" not in name and
             name.startswith("/") and os.path.normpath(name) == name, "Sent-request reader path")
    digest(reader["readerSHA256"])
    need(digest(reader["validatorSHA256"]) == validator_sha256, "Sent-request validator source")
    version = reader["readerVersion"]
    need(type(version) is str and 0 < len(version) <= 4096 and "\0" not in version, "Sent-request reader version")
    expected = {(abi, library): role for abi in ("arm64-v8a", "armeabi-v7a", "x86_64")
                for library, role in (("libavformat.so", "defined-provider"), ("libmpv.so", "undefined-import"))}
    need(type(value["libraries"]) is list and len(value["libraries"]) == len(expected), "Sent-request ABI matrix")
    seen = set()
    for row in value["libraries"]:
        keys(row, "abi library role binarySHA256 dynsymTextSHA256 symbols")
        identity = (row["abi"], row["library"])
        need(identity in expected and identity not in seen and row["role"] == expected[identity], "Sent-request ABI/library role")
        seen.add(identity)
        entry = "jni/" + row["abi"] + "/" + row["library"]
        need(entry in records and digest(row["binarySHA256"]) == records[entry]["sha256"], "Sent-request inspected JNI bytes")
        digest(row["dynsymTextSHA256"])
        need(type(row["symbols"]) is list and len(row["symbols"]) == len(functions), "Dynamic bridge function count")
        names = []
        for symbol in row["symbols"]:
            keys(symbol, "name version defaultVersion type binding visibility section")
            name, version = symbol["name"], symbol["version"]
            need(name in functions and name not in names and symbol["type"] == "FUNC" and
                 symbol["binding"] == "GLOBAL" and symbol["visibility"] == "DEFAULT", "Sent-request exact function identity")
            names.append(name)
            need(type(symbol["defaultVersion"]) is bool and (version is None or
                 type(version) is str and re.fullmatch(r"[A-Za-z_][A-Za-z0-9_.-]{0,127}", version)) and
                 (not symbol["defaultVersion"] or version is not None), "Sent-request versioned symbol identity")
            section = symbol["section"]
            need(type(section) is str and (section == "UND" if row["role"] == "undefined-import" else
                 re.fullmatch(r"[0-9]+", section) is not None and int(section) > 0), "Sent-request function definition/import role")
        need(names == sorted(functions), "Dynamic bridge canonical function order")
    need(seen == set(expected), "Sent-request complete ABI/library coverage")


def sent_request_abi(value, records, validator_sha256):
    dynamic_bridge_abi(value, records, validator_sha256, SENT_FFMPEG_FUNCTIONS, 2, True)


def reference_reader_abi(value, records, validator_sha256, expected_reader):
    dynamic_bridge_abi(value, records, validator_sha256, REFERENCE_FFMPEG_FUNCTIONS, 1, False)
    need(value["reader"] == expected_reader, "Finite-reader and sent-request inspector identity")


def private_owner_abi(value, records, expected_reader):
    """Validate source-bound private-code inspection metadata, without an inspector."""
    keys(value, "schema reader libraries")
    need(type(value["schema"]) is int and value["schema"] == 1 and value["reader"] == expected_reader,
         "Private owner ABI schema/reader correspondence")
    expected = {(abi, "libmpv.so") for abi in ("arm64-v8a", "armeabi-v7a", "x86_64")}
    need(type(value["libraries"]) is list and len(value["libraries"]) == 3, "Private owner ABI matrix")
    seen = set()
    for row in value["libraries"]:
        keys(row, "abi library binarySHA256 symtabTextSHA256 symbols")
        identity = (row["abi"], row["library"])
        need(identity in expected and identity not in seen, "Private owner library identity")
        seen.add(identity)
        entry = "jni/" + row["abi"] + "/libmpv.so"
        need(entry in records and digest(row["binarySHA256"]) == records[entry]["sha256"],
             "Private owner inspected packaged bytes")
        digest(row["symtabTextSHA256"])
        need(type(row["symbols"]) is list and len(row["symbols"]) == len(PRIVATE_MPV_FUNCTIONS),
             "Private owner function count")
        names = []
        for symbol in row["symbols"]:
            keys(symbol, "name size type binding visibility section")
            name = symbol["name"]
            need(name in PRIVATE_MPV_FUNCTIONS and name not in names and symbol["type"] == "FUNC" and
                 (symbol["binding"], symbol["visibility"]) in {("LOCAL", "DEFAULT"), ("LOCAL", "HIDDEN"),
                                                              ("GLOBAL", "HIDDEN")},
                 "Private owner nonexported exact code identity")
            names.append(name)
            need(integer(symbol["size"], 512 * MIB) > 0 and type(symbol["section"]) is str and
                 re.fullmatch(r"[0-9]+", symbol["section"]) and int(symbol["section"]) > 0,
                 "Private owner nonzero defined code")
        need(names == sorted(PRIVATE_MPV_FUNCTIONS), "Private owner canonical function order")
    need(seen == expected, "Private owner complete three-ABI coverage")


def android(archive, inputs, recipe):
    evidence = load(read(archive, "android-artifact-evidence.json"))
    keys(evidence, "aarSHA256 libraries runtimeSecurityTested appAndSeamBindingChanged promotionEligible sentRequestABI privateOwnerABI referenceReaderABI" +
         (" inspection" if "inspection" in evidence else ""))
    need(evidence["aarSHA256"] == inputs["libmpv-release-candidate.aar"]["sha256"] and
         all(evidence[key] is False for key in ("runtimeSecurityTested", "appAndSeamBindingChanged", "promotionEligible")), "Android receipt boundary")
    with archive.open("libmpv-release-candidate.aar") as stream, zip_open(stream) as aar:
        files = zip_index(aar)
    jni = {name: row for name, row in files.items() if name.startswith("jni/")}
    admitted, records = {"arm64-v8a", "armeabi-v7a", "x86_64"}, {}
    need(type(evidence["libraries"]) is list and len(evidence["libraries"]) <= 256, "Android library rows")
    for row in evidence["libraries"]:
        keys(row, "entry sha256 bytes elfIdentityChecked loadAlignments page16KiBChecked")
        integer(row["bytes"], 512 * MIB)
        digest(row["sha256"])
        name = path(row["entry"])
        need(name in jni and name not in records and len(name.split("/")) == 3 and name.endswith(".so"), "Android JNI identity")
        need(row["elfIdentityChecked"] is True and row["page16KiBChecked"] is (name.split("/")[1] != "armeabi-v7a") and
             type(row["loadAlignments"]) is list and row["loadAlignments"] and
             all(type(n) is int and n > 0 and (name.split("/")[1] == "armeabi-v7a" or n >= 16384) for n in row["loadAlignments"]), "Android inspection flags")
        need(jni[name]["kind"] == "file" and {key: jni[name][key] for key in ("bytes", "sha256")} ==
             {"bytes": row["bytes"], "sha256": row["sha256"]}, "Android JNI byte correspondence")
        records[name] = row
    required = {"libmpv.so", "libplayer.so", "libc++_shared.so", "libavcodec.so", "libavformat.so", "libavutil.so", "libavfilter.so", "libavdevice.so", "libswresample.so", "libswscale.so"}
    need(set(records) == set(jni) and {name.split("/")[1] for name in jni} == admitted and all(
         required <= {name.split("/")[-1] for name in jni if name.startswith("jni/" + abi + "/")} for abi in admitted), "Android ABI/library coverage")
    sent_request_abi(evidence["sentRequestABI"], records, recipe["scripts/native-media-hosted/evidence.py"])
    reference_reader_abi(evidence["referenceReaderABI"], records,
                         recipe["scripts/native-media-hosted/evidence.py"], evidence["sentRequestABI"]["reader"])
    private_owner_abi(evidence["privateOwnerABI"], records, evidence["sentRequestABI"]["reader"])
    if "inspection" in evidence:
        need(evidence["inspection"] == evidence["sentRequestABI"]["reader"] and
             evidence["inspection"]["mode"] == "explicit-read-only-inspector", "Separate explicit inspector identity")
    else:
        need(evidence["sentRequestABI"]["reader"]["mode"] == "hosted-ndk-reader", "Default hosted reader identity")


def shaderc_remote_target(package):
    """Authenticate Shaderc's published remote target before local rewrites."""
    need(isinstance(package, str), "Apple package source text")
    need(len(re.findall(r'\bname:\s*"Libshaderc_combined"', package)) == 1,
         "Unique Shaderc Package.swift target")
    pattern = re.compile(
        r'\.binaryTarget\(\s*name:\s*"Libshaderc_combined",\s*'
        r'url:\s*"([^"]+)",\s*checksum:\s*"([0-9a-f]{64})"\s*\)',
        re.DOTALL)
    matches = pattern.findall(package)
    need(len(matches) == 1 and matches[0] == (SHADERC_REMOTE_URL, SHADERC_SOURCE_SPECS[1][2]),
         "Exact published Shaderc remote target")


def shaderc_receipt(value, source_rows, validator_sha256, retained_all_rows):
    """Validate the producer receipt without importing or executing evidence.py."""
    need(type(retained_all_rows) is dict, "Authenticated retained Shaderc all-ZIP index")
    keys(value, "schema profile wrapperVersion validatorSHA256 reader sources matrix runtimeSecurityTested promotionEligible")
    need(type(value["schema"]) is int and value["schema"] == 1 and
         value["profile"] == NATIVE_UPGRADES_PROFILE and
         value["wrapperVersion"] == SHADERC_WRAPPER_VERSION and
         value["runtimeSecurityTested"] is False and value["promotionEligible"] is False,
         "Shaderc receipt schema/profile boundary")
    digest(validator_sha256)
    need(value["validatorSHA256"] == validator_sha256, "Shaderc receipt validator identity")
    reader = value["reader"]
    keys(reader, "mode requestedReader resolvedReader readerSHA256 toolchainReader toolchainSHA256 toolchainVersion")
    need(reader["mode"] == "xcrun-resolved-lipo" and reader["requestedReader"] == "/usr/bin/xcrun" and
         reader["toolchainReader"] == "/usr/bin/xcodebuild" and
         isinstance(reader["resolvedReader"], str) and reader["resolvedReader"].startswith("/") and
         "\x00" not in reader["resolvedReader"] and isinstance(reader["toolchainVersion"], str) and
         len(reader["resolvedReader"]) <= 4096 and
         reader["toolchainVersion"].strip() and "\x00" not in reader["toolchainVersion"] and
         len(reader["toolchainVersion"]) <= 4096,
         "Shaderc reader identity")
    digest(reader["readerSHA256"])
    digest(reader["toolchainSHA256"])
    expected_sources = [dict(name=name, bytes=bytes_, sha256=checksum)
                        for name, bytes_, checksum in SHADERC_SOURCE_SPECS]
    need(type(source_rows) is list and source_rows == expected_sources,
         "Pinned Shaderc source bodies")
    sources = value["sources"]
    need(type(sources) is list and len(sources) == len(expected_sources), "Shaderc receipt source rows")
    for row in sources:
        keys(row, "name bytes sha256")
        integer(row["bytes"], 8 * 1024**3)
        digest(row["sha256"])
    need(sources == expected_sources, "Shaderc receipt source identity")
    expected = {(slice_name, arch):
                "lib/" + platform_name + "/thin/" + arch + "/lib/libshaderc_combined.a"
                for slice_name, arch, platform_name in SHADERC_MATRIX}
    matrix = value["matrix"]
    need(type(matrix) is list and len(matrix) == len(expected), "Shaderc exact matrix row count")
    observed = set()
    for row in matrix:
        keys(row, "slice arch allZipEntry allArchiveSHA256 xcArchiveSHA256 equal")
        need(isinstance(row["slice"], str) and isinstance(row["arch"], str),
             "Shaderc matrix identity types")
        identity = (row["slice"], row["arch"])
        need(identity in expected and identity not in observed and
             row["allZipEntry"] == expected[identity], "Shaderc matrix entry path")
        digest(row["allArchiveSHA256"])
        digest(row["xcArchiveSHA256"])
        need(row["equal"] is True and row["allArchiveSHA256"] == row["xcArchiveSHA256"],
             "Shaderc per-architecture digest equality")
        retained = retained_all_rows.get(row["allZipEntry"])
        need(isinstance(retained, dict) and retained.get("kind") == "file" and
             retained.get("sha256") == row["allArchiveSHA256"],
             "Shaderc matrix digest differs from retained all-ZIP member")
        observed.add(identity)
    need(observed == set(expected), "Shaderc exact nine-architecture matrix")


def openssl_effective_configuration(value, environment, target):
    """Validate the exact configdata.pm whitelist without executing its producer."""
    need(type(value) is dict and set(value) == set(OPENSSL_EFFECTIVE_KEYS),
         "OpenSSL effective configuration keys differ from the fixed whitelist")
    for key in OPENSSL_EFFECTIVE_KEYS:
        item = value[key]
        if key == "CROSS_COMPILE":
            need(item is None, "OpenSSL CROSS_COMPILE must be JSON null for this profile")
            continue
        if isinstance(item, str):
            need(bool(item) and len(item) <= 65536 and "\x00" not in item,
                 "OpenSSL effective configuration string bound")
        else:
            need(type(item) is list and len(item) <= 4096 and
                 all(isinstance(part, str) and part and len(part) <= 65536 and
                     "\x00" not in part for part in item),
                 "OpenSSL effective configuration list bound")
    need(value["target"] == target and value["CC"] == environment["CC"] and
         value["CXX"] == environment["CXX"] and value["AR"] == environment["AR"] and
         value["RANLIB"] == environment["RANLIB"] and value["ARFLAGS"] == ["qc"],
         "OpenSSL effective compiler/tool configuration differs from the environment")
    need(value["CFLAGS"] == [environment["CFLAGS"]] and
         value["CPPFLAGS"] == [environment["CPPFLAGS"]] and
         value["CXXFLAGS"] == [environment["CXXFLAGS"]] and
         value["LDFLAGS"] == [environment["LDFLAGS"]],
         "OpenSSL effective make flags differ from the fixed environment")
    need(value["lib_cppflags"] == "-DL_ENDIAN", "OpenSSL effective library CPP flags differ")
    cflags = value["cflags"] if type(value["cflags"]) is list else [value["cflags"]]
    need("-fno-common" in cflags, "OpenSSL effective C flags omit the fixed target flag")


def openssl_environment(value, platform, arch, sdk_root, source_directory, build_directory):
    need(type(value) is dict and set(value) == set(OPENSSL_ENV_KEYS),
         "OpenSSL environment keys differ from the fixed build map")
    need(all(isinstance(value[key], str) and len(value[key]) <= 65536 and "\x00" not in value[key]
             for key in OPENSSL_ENV_KEYS),
         "OpenSSL environment value bound")
    need(value["CC"] == "/usr/bin/clang" and value["CXX"] == "/usr/bin/clang++" and
         value["CURRENT_ARCH"] == arch and value["LC_CTYPE"] == "C" and
         value["PKG_CONFIG_PATH"] == "" and value["PATH"] == OPENSSL_DEFAULT_PATH and
         value["ARFLAGS"] == "qc" and value["MAKEFLAGS"] == "-j1" and
         value["CMAKE_BUILD_PARALLEL_LEVEL"] == "1" and value["CARGO_BUILD_JOBS"] == "1",
         "OpenSSL fixed environment identity")
    for key, suffix in (("AR", "ar"), ("RANLIB", "ranlib")):
        path = value[key]
        need(path.startswith("/") and ".." not in Path(path).parts and len(path) <= 4096 and
             Path(path).name == suffix and
             re.fullmatch(r"/.+/Toolchains/[^/]+\.xctoolchain/usr/bin/" + suffix, path),
             "OpenSSL selected absolute SDK tool: " + key)
    sdk = Path(sdk_root)
    need(sdk_root.startswith("/") and "\x00" not in sdk_root and ".." not in sdk.parts,
         "OpenSSL SDK root is not a safe absolute path")
    sdk_suffix = {"ios": ("iPhoneOS", "iPhoneOS.sdk"),
                  "isimulator": ("iPhoneSimulator", "iPhoneSimulator.sdk"),
                  "tvos": ("AppleTVOS", "AppleTVOS.sdk"),
                  "tvsimulator": ("AppleTVSimulator", "AppleTVSimulator.sdk"),
                  "macos": ("MacOSX", "MacOSX.sdk")}[platform]
    sdk_pattern = (r".*/" + re.escape(sdk_suffix[0]) +
                   r"\.platform/Developer/SDKs/" + re.escape(sdk_suffix[0]) +
                   r"(?:[0-9]{1,3}(?:\.[0-9]{1,3}){0,3})?\.sdk")
    need(re.fullmatch(sdk_pattern, str(sdk)),
         "OpenSSL SDK root does not match the fixed platform")
    cpu = "arm64" if arch in ("arm64", "arm64e") else "x86_64"
    minimum = {"ios": "15.0", "isimulator": "15.0", "tvos": "15.0",
               "tvsimulator": "15.0", "macos": "12.0"}[platform]
    target = {"ios": cpu + "-apple-ios" + minimum,
              "isimulator": cpu + "-apple-ios" + minimum + "-simulator",
              "tvos": cpu + "-apple-tvos" + minimum,
              "tvsimulator": cpu + "-apple-tvos" + minimum + "-simulator",
              "macos": cpu + "-apple-macos" + minimum}[platform]
    minimum_flag = {"ios": "-mios-version-min=" + minimum,
                    "isimulator": "-mios-simulator-version-min=" + minimum,
                    "tvos": "-mtvos-version-min=" + minimum,
                    "tvsimulator": "-mtvos-simulator-version-min=" + minimum,
                    "macos": "-mmacosx-version-min=" + minimum}[platform]
    common = "-arch " + arch + " -isysroot " + sdk_root + " -target " + target + " " + minimum_flag
    cflags = common + (" -DHAVE_FORK=0" if platform in ("tvos", "tvsimulator") else "")
    need(value["CFLAGS"] == value["CXXFLAGS"] == cflags + " -O3" and
         value["CPPFLAGS"] == value["ASMFLAGS"] == cflags and
         value["LDFLAGS"] == "-lc++ " + common,
         "OpenSSL compiler/linker flags differ from the fixed platform policy")
    source = Path(source_directory)
    build = Path(build_directory)
    need(source_directory.startswith("/") and build_directory.startswith("/") and
         "\x00" not in source_directory and "\x00" not in build_directory and
         source.name == OPENSSL_ROOT and source.parent.name == "dist" and
         build == source.parent / OPENSSL_OUTPUT_ROOT / platform / "scratch" / arch,
         "OpenSSL source/build directory identity differs from the fixed layout")
    expected_pkg = [str(source.parent / library / platform / "thin" / arch / "lib" / "pkgconfig")
                    for library in OPENSSL_PKG_LIBRARIES]
    expected_pkg.append(str(build / "vortx-sdk-pkgconfig"))
    need(value["PKG_CONFIG_LIBDIR"] == ":".join(expected_pkg),
         "OpenSSL pkg-config target roots differ from the fixed ordered map")


def openssl_target_config(value, platform, arch, target):
    need(isinstance(value, str) and value and len(value.encode("utf-8")) <= MIB and
         "\x00" not in value and value.endswith("\n"),
         "OpenSSL generated target config is bounded text")
    expected = ("my %targets = (\n"
                "    \"" + target + "\" => {\n"
                "        inherit_from => [ \"darwin-common\" ],\n"
                "        CC => \"/usr/bin/clang\",\n"
                "        cflags => \"-fno-common\",\n"
                "        lib_cppflags => \"-DL_ENDIAN\",\n"
                "        bn_ops => \"SIXTY_FOUR_BIT_LONG\",\n"
                "        asm_arch => \"" + ("aarch64" if arch in ("arm64", "arm64e") else "x86_64") + "\",\n"
                "        perlasm_scheme => \"" + ("ios64" if arch in ("arm64", "arm64e") else "macosx") + "\",\n"
                "        sys_id => \"" + ("MACOSX" if platform == "macos" else "iOS") + "\",\n"
                "    },\n"
                ");\n\n")
    need(value == expected, "OpenSSL generated target config differs from the fixed template")


# Exact Root-local LP virtual-source contract. This is distinct from Dovi.
LP_SOURCE_PROFILE = 'root-local-libplacebo-275f-provider-v2'
LP_SOURCE_ROOT = 'libplacebo-7.387.0-275f7dea'
LP_SOURCE_COMMIT = '275f7dea27924cdd34ab2e6c20e448b6bc4fab65'
LP_FULL_VIEW_PROOF_SHA256 = '73e23b6a486ddf6970cecc1e82b0120022ef137bc92c66bd0e7d8f7849280d0d'
LP_FULL_VIEW_DRIVER_SHA256 = 'fbd0f51fd49e9ef1b0fda7cf59f60a84668e0be7e7d05ed31d445eb1e25ee7e9'  # Immutable historical proof73 only.
LP_BUILD_DRIVER_SHA256 = '8d8ef2075dd16115db2ee729eb98796b8c5a647cb285e719776219a9b50593bd'  # Current live/raw source-0 binding.
LP_SOURCE_MAP_SHA256 = 'e3dcbfce9b8c53ed2a3a19a0e5bca6d509f097dd20a505420c4bf86176b3d692'
LP_PARENT_PROOF_SHA256 = '64835c27dff03c3d3ebd282a9d0a483d1a62c7d9db298e8ee5f7dfeef5db27b3'
LP_ACQUIRED_PROOF_SHA256 = 'c8a06528a1d3463812daa35ff57d705a14f33dba839ed319fed8913e43418a18'
LP_ACQUIRED_READBACK_SHA256 = '88ec2e498b9e8667fc732eb6b587c8b84f80d3dc6e49f92c33ea8d46ed5e5d99'
LP_WORK = '/Users/daksh/VortXTV/.worktrees/MPVKit/beta-native-upgrades-20261027'
LP_REQUIRED_GITLINKS = {
    '3rdparty/Vulkan-Headers': '74d8a6cb930c68ef617b202c3ff3c59d919e086b',
    '3rdparty/fast_float': '97b54ca9e75f5303507699d27c6b4f4efe4641a1',
    '3rdparty/glad': '73db193f853e2ee079bf3ca8a64aa2eaf6459043',
    '3rdparty/jinja': '15206881c006c79667fe5154fe80c01c65410679',
    '3rdparty/markupsafe': '297fc8e356e6836a62087949245d09a28e9f1b13',
}
LP_EXCLUDED_GITLINKS = {'demos/3rdparty/nuklear': '242f35efa067a46c595645eeda7b1771ea1f83b1'}
LP_PARENT_GITLINKS = dict(LP_REQUIRED_GITLINKS, **LP_EXCLUDED_GITLINKS)
LP_ROLES = {
  "Vulkan-Headers": {
    "branch": "beta/placebo-7.387.0-74d8a6cb930c",
    "canonical": "/Users/daksh/VortXTV/Vulkan-Headers",
    "commit": "74d8a6cb930c68ef617b202c3ff3c59d919e086b",
    "logical": "Vulkan-Headers",
    "origin": "https://github.com/KhronosGroup/Vulkan-Headers",
    "prefix": "3rdparty/Vulkan-Headers/",
    "tree": "2601bf086adb8bcecd6b2a254338d1062027d526",
    "worktree": "/Users/daksh/VortXTV/.worktrees/Vulkan-Headers/beta/placebo-7.387.0-74d8a6cb930c"
  },
  "fast_float": {
    "branch": "beta/placebo-7.387.0-97b54ca9e75f",
    "canonical": "/Users/daksh/VortXTV/fast_float",
    "commit": "97b54ca9e75f5303507699d27c6b4f4efe4641a1",
    "logical": "fast_float",
    "origin": "https://github.com/fastfloat/fast_float.git",
    "prefix": "3rdparty/fast_float/",
    "tree": "ddba8c52570b3fb36fbf13fe8864f46f128567af",
    "worktree": "/Users/daksh/VortXTV/.worktrees/fast_float/beta/placebo-7.387.0-97b54ca9e75f"
  },
  "glad": {
    "branch": "beta/placebo-7.387.0-73db193f853e",
    "canonical": "/Users/daksh/VortXTV/glad",
    "commit": "73db193f853e2ee079bf3ca8a64aa2eaf6459043",
    "logical": "glad",
    "origin": "https://github.com/Dav1dde/glad",
    "prefix": "3rdparty/glad/",
    "tree": "ee6498929fd8531f2943c18abd274dc76b0f8857",
    "worktree": "/Users/daksh/VortXTV/.worktrees/glad/beta/placebo-7.387.0-73db193f853e"
  },
  "jinja": {
    "branch": "beta/placebo-7.387.0-15206881c006",
    "canonical": "/Users/daksh/VortXTV/jinja",
    "commit": "15206881c006c79667fe5154fe80c01c65410679",
    "logical": "jinja",
    "origin": "https://github.com/pallets/jinja",
    "prefix": "3rdparty/jinja/",
    "tree": "e200557b4756d9367d7a08930480efe5ad867bc5",
    "worktree": "/Users/daksh/VortXTV/.worktrees/jinja/beta/placebo-7.387.0-15206881c006"
  },
  "markupsafe": {
    "branch": "beta/placebo-7.387.0-297fc8e356e6",
    "canonical": "/Users/daksh/VortXTV/markupsafe",
    "commit": "297fc8e356e6836a62087949245d09a28e9f1b13",
    "logical": "markupsafe",
    "origin": "https://github.com/pallets/markupsafe",
    "prefix": "3rdparty/markupsafe/",
    "tree": "f6cc9d32027d928d7306c3d15e4f9e1653d6de62",
    "worktree": "/Users/daksh/VortXTV/.worktrees/markupsafe/beta/placebo-7.387.0-297fc8e356e6"
  },
  "parent": {
    "branch": "beta/libplacebo-7.387.0-275f7dea",
    "canonical": "/Users/daksh/VortXTV/libplacebo",
    "commit": "275f7dea27924cdd34ab2e6c20e448b6bc4fab65",
    "logical": "libplacebo-7.387.0-275f7dea",
    "origin": "https://code.videolan.org/videolan/libplacebo.git",
    "prefix": "",
    "tree": "9e95f4eff8376fa4bc5c9b932953946ee27dc443",
    "worktree": "/Users/daksh/VortXTV/.worktrees/libplacebo/beta/libplacebo-7.387.0-275f7dea"
  }
}
LP_EMPTY_SHA256 = hashlib.sha256(b'').hexdigest()


def _lp_need(ok, message):
    if not ok:
        raise ValueError('libplacebo virtual source: ' + message)


def _lp_keys(value, names):
    _lp_need(type(value) is dict and set(value) == set(names.split()), 'exact object fields')


def _lp_sha(body):
    return hashlib.sha256(body).hexdigest()


def _lp_name(value):
    _lp_need(type(value) is str and value and len(value.encode('utf-8')) <= 4096
             and value.isprintable() and not value.startswith('/') and '\\' not in value and ':' not in value
             and all(p not in ('', '.', '..') and p.casefold() != '.git' for p in value.split('/')), 'safe relative path')
    return value


def _lp_json(body):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            _lp_need(key not in result, 'duplicate JSON key')
            result[key] = value
        return result
    _lp_need(type(body) is bytes and len(body) <= 2 * 1024**2, 'bounded JSON body')
    return json.loads(body.decode('utf-8', 'strict'), object_pairs_hook=unique)


def _lp_utf8(value):
    _lp_need(type(value) is str, 'retained UTF8 text')
    body = value.encode('utf-8', 'strict')
    _lp_need(len(body) <= 2 * 1024**2, 'retained UTF8 byte bound')
    return body


def _lp_map(body):
    _lp_need(_lp_sha(body) == LP_SOURCE_MAP_SHA256, 'exact reviewed 853-body source map')
    value = _lp_json(body)
    _lp_keys(value, 'schema parentHead parentReceiptSHA256 acquiredResultSHA256 rootReadbackSHA256 demos excludedUnresolvedGitlinks files completeNativeAcceptance buildCompilerOrABIInvoked')
    _lp_need(type(value['schema']) is int and value['schema'] == 1 and value['parentHead'] == LP_SOURCE_COMMIT
             and value['parentReceiptSHA256'] == LP_PARENT_PROOF_SHA256
             and value['acquiredResultSHA256'] == LP_ACQUIRED_PROOF_SHA256
             and value['rootReadbackSHA256'] == LP_ACQUIRED_READBACK_SHA256
             and value['demos'] is False and value['completeNativeAcceptance'] is False
             and value['buildCompilerOrABIInvoked'] is False
             and value['excludedUnresolvedGitlinks'] == LP_EXCLUDED_GITLINKS, 'map source/profile/no-build boundary')
    _lp_need(type(value['files']) is list and len(value['files']) == 853, 'all853 source bodies')
    rows, folded, total = {}, set(), 0
    for row in value['files']:
        _lp_keys(row, 'path gitMode gitObject bytes sha256')
        name = _lp_name(row['path'])
        _lp_need(name not in rows and name.casefold() not in folded
                 and row['gitMode'] in ('100644', '100755')
                 and type(row['gitObject']) is str and re.fullmatch('[0-9a-f]{40}', row['gitObject'])
                 and type(row['bytes']) is int and 0 <= row['bytes'] <= 64 * 1024**2
                 and type(row['sha256']) is str and re.fullmatch('[0-9a-f]{64}', row['sha256'])
                 and not any(name == p or name.startswith(p + '/') for p in LP_EXCLUDED_GITLINKS), 'exact regular source body identity')
        rows[name] = row
        folded.add(name.casefold())
        total += row['bytes']
    _lp_need(total == 49476848, 'all source bytes')
    _lp_need(sum(any(name.startswith(prefix + '/') for prefix in LP_REQUIRED_GITLINKS) for name in rows) == 602, 'required provider body set')
    return rows


def _lp_role_rows(mapping, role):
    prefix = LP_ROLES[role]['prefix']
    if role == 'parent':
        rows = {name: row for name, row in mapping.items()
                if not any(name.startswith(p + '/') for p in LP_REQUIRED_GITLINKS)}
        return dict(rows, **{name: {'gitMode': '160000', 'gitObject': commit}
                             for name, commit in LP_PARENT_GITLINKS.items()})
    return {name[len(prefix):]: row for name, row in mapping.items() if name.startswith(prefix)}


def _lp_role_index(mapping, role):
    rows = _lp_role_rows(mapping, role)
    return b''.join((row['gitMode'] + ' ' + row['gitObject'] + ' 0\t' + name + '\0').encode('utf-8')
                    for name, row in sorted(rows.items(), key=lambda item: item[0].encode('utf-8')))


def _lp_check_body(body, row, mode):
    _lp_need(type(body) is bytes and type(mode) is int and mode == (0o755 if row['gitMode'] == '100755' else 0o644)
             and len(body) == row['bytes'] and _lp_sha(body) == row['sha256']
             and hashlib.sha1(b'blob ' + str(len(body)).encode() + b'\0' + body).hexdigest() == row['gitObject'], 'raw body bytes/mode/Git blob differ')


def _lp_full_view_proof(body):
    _lp_need(_lp_sha(body) == LP_FULL_VIEW_PROOF_SHA256, 'exact genuine Root full-name corrected-helper readback')
    value = _lp_json(body)
    _lp_keys(value, 'actual actualResultSHA256 allTargetBodiesModesAndGitIDsIndependentlyRead arrangement bytes conservedInputs files gitMetadataOrSymlinks helperSHA256 historicalShortViewProof markerSHA256 nativeCompileOrRuntimeAccepted prospectiveMainSHA256 rawCaptureOrGenuineGitProviderWitnessAccepted schema source')
    _lp_need(value['schema'] == 'vortx-root-libplacebo-fullpath-source-readback-v1'
             and value['source'] == LP_WORK + '/dist/' + LP_SOURCE_ROOT
             and type(value['files']) is int and value['files'] == 853
             and type(value['bytes']) is int and value['bytes'] == 49476848
             and type(value['conservedInputs']) is int and value['conservedInputs'] == 864
             and value['markerSHA256'] == LP_SOURCE_MAP_SHA256
             and value['helperSHA256'] == 'ed2b5b2c2fd45b6c03b6cf0ea5fc707b080f05bdb6f40dd270594ae2acdca617'
             and value['prospectiveMainSHA256'] == LP_FULL_VIEW_DRIVER_SHA256
             and value['allTargetBodiesModesAndGitIDsIndependentlyRead'] is True
             and value['gitMetadataOrSymlinks'] is False
             and value['nativeCompileOrRuntimeAccepted'] is False
             and value['rawCaptureOrGenuineGitProviderWitnessAccepted'] is False,
             'actual full-name body/helper proof only; provider capture/native acceptance stays separate')
    return value


def _lp_admission(body, mapping, proof_body):
    value = _lp_json(body)
    _lp_keys(value, 'schema profile rootReviewedGenuineProviders rootReviewedFullNameBuildView rootReviewedCurrentBuildDriver currentBuildDriverSHA256 sourceMapSHA256 parentProofSHA256 acquisitionProofSHA256 acquisitionReadbackSHA256 fullBuildViewProofSHA256 roles')
    _lp_need(type(value['schema']) is int and value['schema'] == 2 and value['profile'] == LP_SOURCE_PROFILE
             and value['rootReviewedGenuineProviders'] is True and value['rootReviewedFullNameBuildView'] is True
             and value['rootReviewedCurrentBuildDriver'] is True
             and value['currentBuildDriverSHA256'] == LP_BUILD_DRIVER_SHA256
             and value['sourceMapSHA256'] == LP_SOURCE_MAP_SHA256 and value['parentProofSHA256'] == LP_PARENT_PROOF_SHA256
             and value['acquisitionProofSHA256'] == LP_ACQUIRED_PROOF_SHA256
             and value['acquisitionReadbackSHA256'] == LP_ACQUIRED_READBACK_SHA256
             and value['fullBuildViewProofSHA256'] == _lp_sha(proof_body)
             and type(value['roles']) is dict and set(value['roles']) == set(LP_ROLES), 'separate Root-reviewed exact LP provider admission')
    _lp_full_view_proof(proof_body)
    for role, pin in value['roles'].items():
        _lp_keys(pin, 'tree indexSHA256 trackedDiffSHA256 registryRowSHA256')
        _lp_need(pin['tree'] == LP_ROLES[role]['tree']
                 and pin['indexSHA256'] == _lp_sha(_lp_role_index(mapping, role))
                 and pin['trackedDiffSHA256'] == LP_EMPTY_SHA256
                 and type(pin['registryRowSHA256']) is str and re.fullmatch('[0-9a-f]{64}', pin['registryRowSHA256']), 'exact provider tree/index/clean-diff/registry identity')
    return value


def _lp_witness(value):
    _lp_keys(value, 'schema profile currentBuildDriverSHA256 sourceMapUTF8 sourceMapSHA256 admissionUTF8 admissionSHA256 fullBuildViewProofUTF8 fullBuildViewProofSHA256 providers demos excludedUnresolvedGitlinks completeNativeAcceptance')
    _lp_need(type(value['schema']) is int and value['schema'] == 2 and value['profile'] == LP_SOURCE_PROFILE
             and value['currentBuildDriverSHA256'] == LP_BUILD_DRIVER_SHA256
             and value['demos'] is False and value['excludedUnresolvedGitlinks'] == LP_EXCLUDED_GITLINKS
             and value['completeNativeAcceptance'] is False and value['sourceMapSHA256'] == LP_SOURCE_MAP_SHA256, 'source-bound no-build/no-demo witness')
    map_body, admission_body, proof_body = (_lp_utf8(value[key]) for key in ('sourceMapUTF8', 'admissionUTF8', 'fullBuildViewProofUTF8'))
    mapping = _lp_map(map_body)
    _lp_need(_lp_sha(admission_body) == value['admissionSHA256'] and _lp_sha(proof_body) == value['fullBuildViewProofSHA256'], 'retained witness raw bodies')
    admission = _lp_admission(admission_body, mapping, proof_body)
    expected = {role: dict(spec, **admission['roles'][role]) for role, spec in LP_ROLES.items()}
    _lp_need(type(value['providers']) is dict and value['providers'] == expected, 'all six exact genuine provider witnesses')
    return mapping, admission


def validate_libplacebo_virtual_gitlinks(row, files):
    _lp_need(row.get('directory') == LP_SOURCE_ROOT and row.get('commit') == LP_SOURCE_COMMIT
             and type(row.get('root')) is str and re.fullmatch('source-[0-9]+', row['root']), 'exact LP virtual group')
    mapping, _ = _lp_witness(row['placeboSource'])
    _lp_need(type(row.get('gitlinks')) is list and len(row['gitlinks']) == 6, 'all six pinned LP parent links')
    links = {}
    for link in row['gitlinks']:
        _lp_keys(link, 'path commit')
        _lp_need(link['path'] not in links, 'duplicate LP parent link')
        links[link['path']] = link['commit']
    _lp_need(links == LP_PARENT_GITLINKS, 'exact LP parent link identities including excluded Nuklear')
    expected = {row['root'] + '/' + name for name in mapping}
    _lp_need(set(files) == expected, 'all853 virtual LP files; no extras/excluded bodies')
    for prefix in LP_REQUIRED_GITLINKS:
        _lp_need(any(name.startswith(row['root'] + '/' + prefix + '/') for name in files), 'required LP provider descendants')
    for name, pin in mapping.items():
        item = files[row['root'] + '/' + name]
        _lp_need(item == {'kind': 'file', 'mode': 0o755 if pin['gitMode'] == '100755' else 0o644,
                         'bytes': pin['bytes'], 'sha256': pin['sha256']}, 'LP declared body/mode correspondence')
    _lp_need(all(item.get('tracked') is True for item in row['files']), 'all virtual LP bodies are genuine source-tracked')
    return links


def libplacebo_virtual_raw_sources(archive, row, captured):
    _lp_need(type(captured.get('source-0/Sources/BuildScripts/XCFrameworkBuild/main.swift')) is bytes
             and _lp_sha(captured['source-0/Sources/BuildScripts/XCFrameworkBuild/main.swift']) == LP_BUILD_DRIVER_SHA256,
             'retained raw LP build driver binds demos=false')
    mapping, _ = _lp_witness(row['placeboSource'])
    prefix, seen = row['root'] + '/', set()
    with archive.open('native-sources-v2.tar.gz') as stream, tarfile.open(fileobj=stream, mode='r|gz') as native:
        for member in native:
            if not member.name.startswith(prefix):
                continue
            name = member.name[len(prefix):]
            _lp_need(name in mapping and name not in seen and member.isfile() and not member.islnk()
                     and member.size == mapping[name]['bytes'], 'exact raw LP archive member')
            with native.extractfile(member) as incoming:
                body = incoming.read(64 * 1024**2 + 1)
            _lp_check_body(body, mapping[name], member.mode)
            seen.add(name)
    _lp_need(seen == set(mapping), 'complete raw LP Git-blob preservation')


# Exact full FFmpeg/mpv plain-source views. Ordinary Git roots keep their old path.
PLAYER_PLAIN_PROFILE = 'root-local-ffmpeg-mpv-full-plain-source-v1'
PLAYER_PLAIN_WORK = '/Users/daksh/VortXTV/.worktrees/MPVKit/beta-native-upgrades-20261027'
PLAYER_PLAIN_PREPARATION = '/Users/daksh/VortXTV/_recovery/resume-20261029/ffmpeg-mpv-selected-leaves-v1/successor-v2/source-preparation'
PLAYER_PLAIN_MATERIALIZER_SHA256 = '1aebc8e3fd216ea8dc9cdcc4f9a9ef23f4d67974c3c395ac078b184c87c3840c'
PLAYER_PLAIN_FREEZE_SHA256 = '377c9f76b6bda254546a4cc40c7237e4444267865263d70419b62c1db4e19a2c'
PLAYER_PLAIN_DRIVER_SHA256 = '8d8ef2075dd16115db2ee729eb98796b8c5a647cb285e719776219a9b50593bd'
PLAYER_PLAIN_SPECS = {
    'FFmpeg': {'directory': 'FFmpeg-9.0.2-946fcce0', 'base': '946fcce07b6dcd0331c8cc609192aeff5e1924f8',
               'tree': 'b3071e6c198a5b8511acc8ebc2ac319bd4a4496a',
               'canonical': '/Users/daksh/VortXTV/MPVKit/dist/FFmpeg-9.0-6e851934',
               'objects': '/Users/daksh/VortXTV/MPVKit/dist/FFmpeg-9.0-6e851934/.git/objects', 'alternate': None},
    'libmpv': {'directory': 'libmpv-master-8c67647b', 'base': '8c67647b50059406c5c0444903597281b81516cf',
               'tree': '38409515de30dd68bb28cdcc5dcba714a9df57f7',
               'canonical': '/Users/daksh/VortXTV/MPVKit/dist/libmpv-master-8c67647b',
               'objects': '/Users/daksh/VortXTV/_recovery/resume-20261027/root-mpv-series-composition-hardened/objects/mpv',
               'alternate': '/Users/daksh/VortXTV/MPVKit/dist/libmpv-master-8c67647b/.git/objects'},
}
PLAYER_PLAIN_COMPOSITIONS = {
    'FFmpeg': (('/Users/daksh/VortXTV/_recovery/resume-20261027/root-carrier-composition-next/accepted-source-map-next/ROOT-ACCEPTANCE.json', '62c794b9e46d67847f08b1c2b58b64ab6b12f9c2913277fc3ef308fea3ffcd97'), ('/Users/daksh/VortXTV/_recovery/resume-20261027/root-carrier-composition-next/accepted-source-map-next/RESULT.json', '89d48bc6894f7cf61d73239c98820270298647e790db2e8dbac7ca183bbd5d07')),
    'libmpv': (('/Users/daksh/VortXTV/_recovery/resume-20261027/root-mpv-series-composition-hardened/ROOT-ACCEPTANCE.json', '343b9b20a4cd8240fe44da80ad2fdfd48429cec4a5c1730687513dcce5f9ba70'), ('/Users/daksh/VortXTV/_recovery/resume-20261027/root-mpv-series-composition-hardened/RESULT.json', 'dee81ca527c72b36a58782a5940f5f500a78dcc290740f6382912acd9fc9647a')),
}
PLAYER_PLAIN_KEYS = ('kCVPixelBufferOpenGLESCompatibilityKey', 'kCVPixelBufferIOSurfaceOpenGLTextureCompatibilityKey')


def _pp_need(ok, message):
    if not ok:
        raise ValueError('full player plain source: ' + message)


def _pp_keys(value, names):
    _pp_need(type(value) is dict and set(value) == set(names.split()), 'exact object fields')


def _pp_equal(left, right):
    if type(left) is not type(right): return False
    if type(left) is dict: return set(left) == set(right) and all(_pp_equal(left[k], right[k]) for k in left)
    if type(left) is list: return len(left) == len(right) and all(_pp_equal(a, b) for a, b in zip(left, right))
    return left == right


def _pp_sha(body):
    return hashlib.sha256(body).hexdigest()


def _pp_digest(value):
    _pp_need(type(value) is str and re.fullmatch('[0-9a-f]{64}', value), 'SHA256 identity')
    return value


def _pp_json(body):
    _pp_need(type(body) is bytes and len(body) <= 16 * 1024**2, 'bounded retained JSON')
    def unique(pairs):
        value = {}
        for key, item in pairs:
            _pp_need(key not in value, 'duplicate JSON key'); value[key] = item
        return value
    return json.loads(body.decode('utf-8', 'strict'), object_pairs_hook=unique,
                      parse_constant=lambda _: _pp_need(False, 'nonfinite JSON'))


def _pp_name(name):
    _pp_need(type(name) is str and name and len(name.encode()) <= 4096 and name.isprintable()
             and not name.startswith('/') and '\\' not in name and ':' not in name
             and all(x not in ('', '.', '..') and x.casefold() != '.git' for x in name.split('/')),
             'safe complete source path')
    # Restrict ambiguous Unicode separators without changing ordinary Git policy.
    _pp_need(unicodedata.normalize('NFC', name) == name and all(
        '/' not in unicodedata.normalize('NFKC', c) and '\\' not in unicodedata.normalize('NFKC', c)
        for c in name if c != '/'), 'unambiguous source name')
    return name


def _pp_tree(mapping):
    root = {}; folded = set()
    for name, row in mapping.items():
        _pp_name(name); _pp_need(name.casefold() not in folded, 'case-colliding original path'); folded.add(name.casefold())
        parts = name.split('/'); node = root
        for part in parts[:-1]:
            existing = node.setdefault(part, {})
            _pp_need(type(existing) is dict, 'original file/link ancestor'); node = existing
        _pp_need(parts[-1] not in node, 'duplicate original path'); node[parts[-1]] = (row['gitMode'], row['gitBlobID'])
    def encode(node):
        rows = []
        for name, item in node.items():
            directory = type(item) is dict
            mode, oid = ('40000', encode(item)) if directory else item
            rows.append((name.encode() + (b'/' if directory else b''),
                         mode.encode() + b' ' + name.encode() + b'\0' + bytes.fromhex(oid)))
        body = b''.join(item for _, item in sorted(rows))
        return hashlib.sha1(b'tree ' + str(len(body)).encode() + b'\0' + body).hexdigest()
    return encode(root)


def _pp_proof(body, family):
    _pp_need(family in PLAYER_PLAIN_SPECS, 'fixed selected family'); spec = PLAYER_PLAIN_SPECS[family]
    value = _pp_json(body)
    _pp_keys(value, 'schema family sourceRoot baseCommit composedTree sourceOnly SDKBuildAccepted materializedSnapshotSHA256 materializedTree originalGitToMaterialized declaredDerivatives canonicalBefore canonicalAfterEqual lsTreeRawSHA256 rootIndependentAcceptance publisherPlainViewIntegrationAccepted')
    _pp_need(value['schema'] == 'vortx-genuine-selected-source-view-v1' and value['family'] == family
             and value['sourceRoot'] == PLAYER_PLAIN_WORK + '/dist/' + spec['directory']
             and value['baseCommit'] == spec['base'] and value['composedTree'] == spec['tree']
             and value['sourceOnly'] is True and value['SDKBuildAccepted'] is False
             and value['canonicalAfterEqual'] is True and value['rootIndependentAcceptance'] is False
             and value['publisherPlainViewIntegrationAccepted'] is False, 'source lineage; no relabeled native acceptance')
    _pp_digest(value['lsTreeRawSHA256']); _pp_digest(value['materializedSnapshotSHA256'])
    mapping, tree = value['originalGitToMaterialized'], value['materializedTree']
    _pp_need(type(mapping) is dict and 0 < len(mapping) <= 65536 and type(tree) is dict, 'complete bounded original/materialized membership')
    directories = set(); total = 0; expected = {}
    for name, row in mapping.items():
        _pp_name(name); _pp_keys(row, 'gitMode gitBlobID originalBytes originalSHA256 materializedBytes materializedSHA256 derivative')
        _pp_need(row['gitMode'] in ('100644', '100755', '120000') and type(row['gitBlobID']) is str
                 and re.fullmatch('[0-9a-f]{40}', row['gitBlobID']) and type(row['derivative']) is bool,
                 'original Git blob/mode and typed derivative')
        for key in ('originalBytes', 'materializedBytes'):
            _pp_need(type(row[key]) is int and 0 <= row[key] <= 64 * 1024**2, 'source body bounds')
        for key in ('originalSHA256', 'materializedSHA256'): _pp_digest(row[key])
        total += row['materializedBytes']; _pp_need(total <= 1024**3, 'complete source byte bound')
        directories.update(str(x) for x in Path(name).parents if str(x) != '.')
        actual = tree.get(name)
        if row['gitMode'] == '120000':
            _pp_keys(actual, 'kind mode target'); _pp_need(actual['kind'] == 'symlink' and actual['mode'] == 0o777, 'source link mode')
            _pp_need(type(actual['target']) is str, 'source link text'); raw = actual['target'].encode()
            _pp_need(not row['derivative'] and len(raw) == row['materializedBytes'] and _pp_sha(raw) == row['materializedSHA256'], 'link body correspondence')
            expected[name] = dict(kind='symlink', mode=0o777, target=actual['target'], bytes=len(raw), sha256=_pp_sha(raw))
        else:
            mode = 0o755 if row['gitMode'] == '100755' else 0o644
            _pp_need(_pp_equal(actual, dict(kind='file', mode=mode, bytes=row['materializedBytes'], sha256=row['materializedSHA256'])), 'materialized file map/mode')
            expected[name] = dict(actual)
        _pp_need(not row['derivative'] or (family == 'FFmpeg' and name == 'libavcodec/videotoolbox.c'), 'only explicit maintained VideoToolbox derivative')
        if not row['derivative']:
            _pp_need(row['originalBytes'] == row['materializedBytes'] and row['originalSHA256'] == row['materializedSHA256'], 'unchanged source body identity')
    _pp_need(set(tree) == set(mapping) | directories and not set(mapping) & directories
             and len({name.casefold() for name in tree}) == len(tree), 'full collision-free file/link/directory set; no extras')
    _pp_need((family == 'FFmpeg' and mapping.get('libavcodec/videotoolbox.c', {}).get('derivative') is True)
             or (family == 'libmpv' and value['declaredDerivatives'] == []), 'retained two VideoToolbox substitutions or unmodified mpv')
    _pp_need(all(_pp_equal(tree[name], {'kind': 'directory', 'mode': 0o755}) for name in directories), 'explicit materialized directory modes')
    _pp_need(_pp_sha(json.dumps(tree, sort_keys=True, separators=(',', ':')).encode()) == value['materializedSnapshotSHA256']
             and _pp_tree(mapping) == spec['tree'], 'complete cryptographic composed tree and materialized snapshot')
    before = value['canonicalBefore']; _pp_keys(before, 'metadata effectiveHEAD objectStores workingTree')
    _pp_need(type(before['effectiveHEAD']) is dict and type(before['effectiveHEAD'].get('effectiveOID')) is str
             and re.fullmatch('[0-9a-f]{40}', before['effectiveHEAD']['effectiveOID'])
             and type(before['metadata']) is dict and set(before['metadata']) == {'HEAD', 'index', 'config'}
             and type(before['objectStores']) is dict and before['objectStores'], 'retained corrected canonical/effective-HEAD provenance')
    return value, mapping, expected


def _pp_witness(value):
    _pp_keys(value, 'schema profile family currentBuildDriverSHA256 materializerSHA256 materializerFreezeSHA256 proofUTF8 proofSHA256 admissionUTF8 admissionSHA256 originalDerivativesBase64 compositionUTF8')
    family = value['family']; _pp_need(family in PLAYER_PLAIN_SPECS and type(value['schema']) is int and value['schema'] == 1
        and value['profile'] == PLAYER_PLAIN_PROFILE and value['currentBuildDriverSHA256'] == PLAYER_PLAIN_DRIVER_SHA256
        and value['materializerSHA256'] == PLAYER_PLAIN_MATERIALIZER_SHA256 and value['materializerFreezeSHA256'] == PLAYER_PLAIN_FREEZE_SHA256,
        'exact corrected source-control identity')
    _pp_need(type(value['proofUTF8']) is str and type(value['admissionUTF8']) is str, 'retained exact proof/admission text')
    proof_body, admission_body = value['proofUTF8'].encode(), value['admissionUTF8'].encode()
    _pp_need(_pp_sha(proof_body) == value['proofSHA256'] and _pp_sha(admission_body) == value['admissionSHA256'], 'retained exact source receipt bodies')
    _pp_need(type(value['compositionUTF8']) is list and len(value['compositionUTF8']) == 2, 'retained accepted complete-source composition receipts')
    for body_text, (_, expected_sha) in zip(value['compositionUTF8'], PLAYER_PLAIN_COMPOSITIONS[family]):
        _pp_need(type(body_text) is str and len(body_text.encode()) <= 2 * 1024**2 and _pp_sha(body_text.encode()) == expected_sha, 'exact prior accepted 19-patch/29-source or FFmpeg composition body')
    proof, mapping, expected = _pp_proof(proof_body, family); admission = _pp_json(admission_body)
    _pp_keys(admission, 'schema profile currentBuildDriverSHA256 materializerSHA256 materializerFreezeSHA256 rootReviewedGenuineFullSourceProofs rootReviewedAllSourceBodies rootReviewedOriginal19Patch29SourceContracts sourceReviewSHA256 securityReviewSHA256 families nativeOrRuntimeOrShippingAccepted')
    _pp_need(type(admission['schema']) is int and admission['schema'] == 1 and admission['profile'] == PLAYER_PLAIN_PROFILE
        and admission['currentBuildDriverSHA256'] == PLAYER_PLAIN_DRIVER_SHA256
        and admission['materializerSHA256'] == PLAYER_PLAIN_MATERIALIZER_SHA256 and admission['materializerFreezeSHA256'] == PLAYER_PLAIN_FREEZE_SHA256
        and all(admission[key] is True for key in ('rootReviewedGenuineFullSourceProofs', 'rootReviewedAllSourceBodies', 'rootReviewedOriginal19Patch29SourceContracts'))
        and admission['nativeOrRuntimeOrShippingAccepted'] is False and type(admission['families']) is dict
        and set(admission['families']) == set(PLAYER_PLAIN_SPECS), 'explicit genuine Root full-source-only admission')
    _pp_digest(admission['sourceReviewSHA256']); _pp_digest(admission['securityReviewSHA256'])
    for name, row in admission['families'].items():
        _pp_keys(row, 'proofPath proofSHA256 rootActualMaterializationReviewed')
        _pp_need(row['proofPath'] == PLAYER_PLAIN_PREPARATION + '/RUNTIME/' + name + '/source-proof.json'
                 and row['rootActualMaterializationReviewed'] is True, 'fixed actual materialization proof path')
        _pp_digest(row['proofSHA256'])
    _pp_need(admission['families'][family]['proofSHA256'] == value['proofSHA256'], 'admitted exact family source proof')
    originals = value['originalDerivativesBase64']; derived = {name for name, row in mapping.items() if row['derivative']}
    _pp_need(type(originals) is dict and set(originals) == derived, 'all and only original derivative bodies retained')
    for name, encoded in originals.items():
        _pp_need(type(encoded) is str and len(encoded) <= 90 * 1024**2, 'bounded original derivative encoding')
        body = base64.b64decode(encoded, validate=True); row = mapping[name]
        _pp_need(len(body) == row['originalBytes'] and _pp_sha(body) == row['originalSHA256']
                 and hashlib.sha1(b'blob ' + str(len(body)).encode() + b'\0' + body).hexdigest() == row['gitBlobID'], 'original derivative raw Git body')
    return proof, mapping, expected


def _pp_body(body, row, witness, name):
    _pp_need(len(body) == row['materializedBytes'] and _pp_sha(body) == row['materializedSHA256'], 'every archived materialized body')
    original = base64.b64decode(witness['originalDerivativesBase64'][name], validate=True) if row['derivative'] else body
    _pp_need(len(original) == row['originalBytes'] and _pp_sha(original) == row['originalSHA256']
             and hashlib.sha1(b'blob ' + str(len(original)).encode() + b'\0' + original).hexdigest() == row['gitBlobID'], 'every original raw Git blob correspondence')
    if row['derivative']:
        proof = _pp_json(witness['proofUTF8'].encode()); declarations = proof['declaredDerivatives']
        _pp_need(type(declarations) is list and len(declarations) == 2, 'both maintained VideoToolbox substitutions')
        transformed = original
        for literal, declaration in zip(PLAYER_PLAIN_KEYS, declarations):
            _pp_keys(declaration, 'file literal replacement occurrences')
            _pp_need(declaration['file'] == name and declaration['literal'] == literal
                     and declaration['replacement'] == 'kCVPixelBufferMetalCompatibilityKey'
                     and type(declaration['occurrences']) is int and declaration['occurrences'] == transformed.count(literal.encode()), 'exact derivative operation and count')
            transformed = transformed.replace(literal.encode(), b'kCVPixelBufferMetalCompatibilityKey')
        _pp_need(transformed == body, 'only the two declared source transformations')


def _pp_legacy(witness):
    proof, _, _ = _pp_witness(witness)
    # This named legacy artifact is explicitly a typed lineage record, never a fabricated Git diff.
    return (json.dumps({'schema': 'vortx-authenticated-plain-source-lineage-v1', 'family': witness['family'],
        'baseCommit': proof['baseCommit'], 'composedTree': proof['composedTree'], 'proofSHA256': witness['proofSHA256'],
        'materializedSnapshotSHA256': proof['materializedSnapshotSHA256'], 'gitDiff': False}, sort_keys=True, separators=(',', ':')) + '\n').encode()


def _pp_inventory(files, witness, allowed):
    _, mapping, expected = _pp_witness(witness)
    actual = {item['path']: {k: v for k, v in item.items() if k not in ('path', 'tracked')} for item in files}
    _pp_need(len(actual) == len(files) and _pp_equal(actual, expected) and set(allowed) <= set(mapping), 'complete captured source membership/body/mode/link correspondence')
    for item in files:
        _pp_need(type(item['tracked']) is bool and item['tracked'] is (item['path'] not in allowed), 'original recipe-created versus tracked classification')
    return expected


def validate_player_plain_source(row, files):
    witness = row['playerPlainSource']; proof, _, expected = _pp_witness(witness)
    _pp_need(row['directory'] == PLAYER_PLAIN_SPECS[witness['family']]['directory']
             and row['commit'] == proof['baseCommit'] and row['gitlinks'] == [], 'exact plain source group/base and no invented Gitlinks')
    _pp_need(files == {row['root'] + '/' + name: value for name, value in expected.items()}, 'all declared full-source raw entries')
    return {}


def player_plain_raw_sources(archive, row, captured):
    witness = row['playerPlainSource']; _, mapping, _ = _pp_witness(witness)
    _pp_need(type(captured.get('source-0/Sources/BuildScripts/XCFrameworkBuild/main.swift')) is bytes
             and _pp_sha(captured['source-0/Sources/BuildScripts/XCFrameworkBuild/main.swift']) == PLAYER_PLAIN_DRIVER_SHA256,
             'retained maintained player driver source')
    _pp_need(read(archive, 'source-' + str(row['receiptIndex']) + '.patch') == _pp_legacy(witness),
             'typed plain-source lineage record; never a fabricated Git diff')
    prefix = row['root'] + '/'; seen = set()
    with archive.open('native-sources-v2.tar.gz') as stream, tarfile.open(fileobj=stream, mode='r|gz') as native:
        for member in native:
            if not member.name.startswith(prefix): continue
            name = member.name[len(prefix):]
            _pp_need(name in mapping and name not in seen and not member.islnk(), 'every unique complete source member')
            pin = mapping[name]
            if pin['gitMode'] == '120000':
                _pp_need(member.issym() and member.mode == 0o777 and member.size == 0, 'original source symlink body/mode')
                body = member.linkname.encode()
            else:
                _pp_need(member.isfile() and member.mode == (0o755 if pin['gitMode'] == '100755' else 0o644)
                         and member.size == pin['materializedBytes'], 'original source file mode/size')
                with native.extractfile(member) as incoming: body = incoming.read(64 * 1024**2 + 1)
            _pp_body(body, pin, witness, name); seen.add(name)
    _pp_need(seen == set(mapping), 'every original/materialized source body independently read')


def validate_native_gitlinks(row, files):
    """Authenticate normal recursive links and OpenSSL's bounded no-fetch map."""
    if type(row) is dict and 'playerPlainSource' in row:
        return validate_player_plain_source(row, files)
    if type(row) is dict and 'placeboSource' in row:
        return validate_libplacebo_virtual_gitlinks(row, files)
    need(type(row) is dict and isinstance(row.get("root"), str) and
         isinstance(row.get("commit"), str) and type(row.get("gitlinks")) is list,
         "Native Gitlink row shape")
    links = {}
    for item in row["gitlinks"]:
        keys(item, "path commit")
        name = path(item["path"])
        need(name not in links and re.fullmatch(r"[0-9a-f]{40}", item["commit"]),
             "Gitlink source preservation")
        if row["commit"] != OPENSSL_SOURCE_SHA:
            need(any(name0.startswith(row["root"] + "/" + name + "/") for name0 in files),
                 "Gitlink source preservation")
        links[name] = item["commit"]
    if row["commit"] == OPENSSL_SOURCE_SHA:
        need(links == OPENSSL_GITLINKS and
             not any(any(name0 == row["root"] + "/" + name or
                         name0.startswith(row["root"] + "/" + name + "/")
                        for name in OPENSSL_GITLINKS) for name0 in files),
             "Pinned OpenSSL no-fetch Gitlinks")
    return links


def openssl_receipt(value, validator_sha256):
    """Validate the source-build BOM without importing or executing build code."""
    keys(value, "schema profile sourceProfile version sourceSHA sourceTag validatorSHA256 matrix runtimeSecurityTested promotionEligible")
    need(type(value["schema"]) is int and value["schema"] == 1 and
         value["profile"] == NATIVE_UPGRADES_PROFILE and
         value["sourceProfile"] == OPENSSL_BOM_PROFILE and
         value["version"] == OPENSSL_SOURCE_VERSION and
         value["sourceSHA"] == OPENSSL_SOURCE_SHA and
         value["sourceTag"] == OPENSSL_SOURCE_TAG and
         value["runtimeSecurityTested"] is False and value["promotionEligible"] is False,
         "OpenSSL receipt source/profile boundary")
    digest(validator_sha256)
    need(value["validatorSHA256"] == validator_sha256, "OpenSSL receipt validator identity")
    need(type(value["matrix"]) is list and len(value["matrix"]) == len(OPENSSL_MATRIX),
         "OpenSSL exact nine-row matrix")
    expected = {(platform, arch): (target, slice_name)
                for platform, arch, target, slice_name in OPENSSL_MATRIX}
    observed = set()
    header_hashes = set()
    for row in value["matrix"]:
        keys(row, "platform arch slice configureTarget configureArguments sdkRoot sourceDirectory buildDirectory prefix environment targetConfig targetConfigSHA256 effectiveConfiguration compiled installed outputs")
        identity = (row["platform"], row["arch"])
        need(identity in expected and identity not in observed and
             row["slice"] == expected[identity][1] and
             row["configureTarget"] == expected[identity][0] and
             row["compiled"] is True and row["installed"] is True,
             "OpenSSL row platform/architecture/completion")
        for field in ("sdkRoot", "sourceDirectory", "buildDirectory", "prefix"):
            need(isinstance(row[field], str) and row[field].startswith("/") and
                 "\x00" not in row[field] and len(row[field]) <= 4096,
                 "OpenSSL row bounded absolute path: " + field)
        source_root = Path(row["sourceDirectory"])
        need(source_root.name == OPENSSL_ROOT and source_root.parent.name == "dist",
             "OpenSSL row source root")
        need(Path(row["buildDirectory"]) == source_root.parent / OPENSSL_OUTPUT_ROOT / row["platform"] /
             "scratch" / row["arch"], "OpenSSL row scratch directory")
        need(Path(row["prefix"]) == source_root.parent / OPENSSL_OUTPUT_ROOT / row["platform"] /
             "thin" / row["arch"], "OpenSSL row installed thin directory")
        need(row["prefix"].endswith("/dist/" + OPENSSL_OUTPUT_ROOT + "/" + row["platform"] + "/thin/" + row["arch"]),
             "OpenSSL row thin prefix")
        expected_args = ["--config=" + row["buildDirectory"] + "/vortx-openssl-target.conf",
                         "--prefix=" + row["prefix"], *OPENSSL_CONFIGURE_FLAGS, expected[identity][0]]
        need(row["configureArguments"] == expected_args, "OpenSSL Configure argument identity")
        openssl_environment(row["environment"], row["platform"], row["arch"], row["sdkRoot"],
                            row["sourceDirectory"], row["buildDirectory"])
        openssl_target_config(row["targetConfig"], row["platform"], row["arch"],
                              expected[identity][0])
        need(row["targetConfigSHA256"] == sha(row["targetConfig"].encode("utf-8")),
             "OpenSSL target config digest")
        openssl_effective_configuration(row["effectiveConfiguration"], row["environment"],
                                        expected[identity][0])
        outputs = row["outputs"]
        need(type(outputs) is list and len(outputs) == len(OPENSSL_OUTPUTS), "OpenSSL output count")
        seen = set()
        for output in outputs:
            keys(output, "name path bytes sha256")
            fixed = next((candidate for candidate in OPENSSL_OUTPUTS if candidate[0] == output["name"]), None)
            need(fixed is not None and output["name"] not in seen and output["path"] == fixed[1],
                 "OpenSSL output path/name")
            integer(output["bytes"], fixed[2])
            need(output["bytes"] > 0, "OpenSSL output must not be empty")
            digest(output["sha256"])
            if output["name"] == "opensslv.h":
                header_hashes.add(output["sha256"])
            seen.add(output["name"])
        need(seen == {name for name, _, _ in OPENSSL_OUTPUTS}, "OpenSSL output set")
        observed.add(identity)
    need(observed == set(expected) and len(header_hashes) == 1, "OpenSSL complete matrix/header identity")
    return value


def _zip_resolve(rows, name):
    seen = set()
    for _ in range(16):
        need(name not in seen, "ZIP link cycle")
        seen.add(name)
        row = rows.get(name)
        need(isinstance(row, dict), "ZIP member missing: " + name)
        if row.get("kind") == "file":
            return name
        need(row.get("kind") == "symlink" and isinstance(row.get("target"), str),
             "ZIP member is not a regular file: " + name)
        target = row["target"]
        need(target and len(target.encode("utf-8")) <= 4096 and
             not target.startswith("/") and "\\" not in target and "\x00" not in target and
             target.isprintable(), "unsafe ZIP link target")
        base = name.split("/")[:-1]
        for piece in target.split("/"):
            if piece in ("", "."):
                continue
            if piece == "..":
                need(base, "ZIP link escapes archive root")
                base.pop()
            else:
                base.append(piece)
        name = "/".join(base)
    raise ValueError("ZIP link hop bound")


def _macho_arch_hashes(data):
    """Return bounded universal-binary member hashes; thin archives are one-arch."""
    need(isinstance(data, bytes) and data, "OpenSSL framework binary is empty")
    big_magic = int.from_bytes(data[:4], "big") if len(data) >= 4 else 0
    little_magic = int.from_bytes(data[:4], "little") if len(data) >= 4 else 0
    fat_magic = big_magic if big_magic in (0xCAFEBABE, 0xCAFEBABF) else None
    if fat_magic is None and little_magic in (0xCAFEBABE, 0xCAFEBABF):
        fat_magic = little_magic
    if fat_magic is None:
        return None
    endian = "big" if big_magic in (0xCAFEBABE, 0xCAFEBABF) else "little"
    width = 8 if (big_magic == 0xCAFEBABF or little_magic == 0xCAFEBABF) else 4
    count = int.from_bytes(data[4:8], endian)
    need(0 < count <= 16, "OpenSSL universal-binary slice count")
    entry_size = 32 if width == 8 else 20
    need(8 + count * entry_size <= len(data), "OpenSSL universal-binary header bound")
    result = {}
    ranges = []
    for index in range(count):
        offset = 8 + index * entry_size
        cputype = int.from_bytes(data[offset:offset + 4], endian)
        subtype = int.from_bytes(data[offset + 4:offset + 8], endian)
        if width == 8:
            start = int.from_bytes(data[offset + 8:offset + 16], endian)
            size = int.from_bytes(data[offset + 16:offset + 24], endian)
        else:
            start = int.from_bytes(data[offset + 8:offset + 12], endian)
            size = int.from_bytes(data[offset + 12:offset + 16], endian)
        need(size > 0 and start >= 8 + count * entry_size and start + size <= len(data),
             "OpenSSL universal-binary slice bounds")
        arch = "arm64" if cputype == 0x0100000C and subtype & 0xff != 2 else (
            "arm64e" if cputype == 0x0100000C else "x86_64" if cputype == 0x01000007 else None)
        need(arch is not None and arch not in result, "OpenSSL universal-binary architecture identity")
        result[arch] = (size, sha(data[start:start + size]))
        ranges.append((start, start + size))
    ranges.sort()
    need(all(previous_end <= start for (_, previous_end), (start, _) in zip(ranges, ranges[1:])),
         "OpenSSL universal-binary slices overlap")
    return result


def _openssl_archive_member(archive, rows, name, limit=512 * MIB):
    resolved = _zip_resolve(rows, name)
    data = read(archive, resolved, limit)
    return resolved, data


def openssl_archive_binding(value, zip_bodies):
    """Bind nine BOM rows to the retained Libssl/Libcrypto ZIP members."""
    need(set(zip_bodies) == {"Libssl", "Libcrypto"}, "Retained OpenSSL ZIP bodies")
    archives = {}
    for base, body in zip_bodies.items():
        with io.BytesIO(body) as stream, zip_open(stream, 256) as archive:
            archives[base] = (body, archive.infolist(), zip_index(archive, count=256, total=8 * 1024**3))
    expected_arches = {}
    for platform, arch, _, slice_name in OPENSSL_MATRIX:
        expected_arches.setdefault(slice_name, set()).add(arch)
    rows = {(row["platform"], row["arch"]): row for row in value["matrix"]}
    header_hashes = set()
    for platform, arch, _, slice_name in OPENSSL_MATRIX:
        row = rows[(platform, arch)]
        outputs = {output["name"]: output for output in row["outputs"]}
        for base in ("Libssl", "Libcrypto"):
            body, _, indexed = archives[base]
            with io.BytesIO(body) as stream, zip_open(stream, 256) as archive:
                binary_name = base + ".xcframework/" + slice_name + "/" + base + ".framework/" + base
                _, binary = _openssl_archive_member(archive, indexed, binary_name)
                segments = _macho_arch_hashes(binary)
                if segments is None:
                    need(len(expected_arches[slice_name]) == 1,
                         "OpenSSL thin framework binary used for a multi-arch slice")
                    segments = {next(iter(expected_arches[slice_name])): (len(binary), sha(binary))}
                need(set(segments) == expected_arches[slice_name], "OpenSSL exact framework architecture set")
                expected_output = outputs["libssl.a" if base == "Libssl" else "libcrypto.a"]
                need(segments[arch] == (expected_output["bytes"], expected_output["sha256"]),
                     "OpenSSL framework/static-library byte correspondence")
                header_name = base + ".xcframework/" + slice_name + "/" + base + ".framework/Headers/openssl/opensslv.h"
                need(header_name in indexed, "Missing OpenSSL version header")
                _, header = _openssl_archive_member(archive, indexed, header_name, MIB)
                header_sha = sha(header)
                need(len(header) == outputs["opensslv.h"]["bytes"] and
                     header_sha == outputs["opensslv.h"]["sha256"],
                     "OpenSSL version-header byte correspondence")
                header_hashes.add(header_sha)
    need(len(header_hashes) == 1, "OpenSSL retained version-header correspondence")


def crypto_inline_file(row, maximum, expected_path=None, budget=None):
    keys(row, "path bytes sha256 bodyBase64")
    name = path(row["path"])
    need(expected_path is None or name == expected_path, "Crypto inline file path")
    integer(row["bytes"], maximum)
    need(row["bytes"] > 0 and isinstance(row["bodyBase64"], str) and
         len(row["bodyBase64"]) <= ((maximum + 2) // 3) * 4,
         "Crypto inline file body bound")
    try:
        body = base64.b64decode(row["bodyBase64"].encode("ascii"), validate=True)
    except (UnicodeEncodeError, binascii.Error) as error:
        raise ValueError("Crypto inline file is not canonical base64") from error
    need(base64.b64encode(body).decode("ascii") == row["bodyBase64"] and
         len(body) == row["bytes"] and sha(body) == row["sha256"],
         "Crypto inline file raw-body identity")
    if budget is not None:
        budget[0] += len(body)
        need(budget[0] <= CRYPTO_MAX_INLINE_RAW, "Crypto aggregate inline raw-body cap")
    return body


def crypto_recorded_text(row, label):
    keys(row, "bytes sha256 text")
    need(isinstance(row["text"], str), "Crypto " + label + " text type")
    body = row["text"].encode("utf-8")
    integer(row["bytes"], 16 * MIB)
    need(len(body) == row["bytes"] and sha(body) == row["sha256"],
         "Crypto " + label + " text identity")
    return row["text"]


def crypto_tool_record(row, label):
    keys(row, "resolvedPath path bytes sha256")
    resolved = row["resolvedPath"]
    need(isinstance(resolved, str) and resolved.startswith("/") and "\x00" not in resolved and
         ".." not in Path(resolved).parts and len(resolved) <= 4096 and
         row["path"] == Path(resolved).name,
         "Crypto " + label + " resolved tool path")
    integer(row["bytes"], 512 * MIB)
    need(row["bytes"] > 0, "Crypto " + label + " empty tool")
    digest(row["sha256"])
    return row


def crypto_tools(value):
    keys(value, "xcrun xcodebuild lipo nm toolchainVersion platforms")
    resolved_aliases = {
        "xcrun": {"xcrun"}, "xcodebuild": {"xcodebuild"},
        "lipo": {"lipo"}, "nm": {"nm", "llvm-nm"},
        "ar": {"ar"}, "ranlib": {"ranlib", "libtool"},
    }
    for name in ("xcrun", "xcodebuild", "lipo", "nm"):
        crypto_tool_record(value[name], name)
        need(value[name]["path"] in resolved_aliases[name],
             "Crypto selected tool resolved basename: " + name)
    need(value["xcrun"]["resolvedPath"] == "/usr/bin/xcrun" and
         value["xcodebuild"]["resolvedPath"] == "/usr/bin/xcodebuild",
         "Crypto fixed Apple tool entry points")
    crypto_recorded_text(value["toolchainVersion"], "toolchain version")
    need(type(value["platforms"]) is dict and set(value["platforms"]) == set(CRYPTO_PLATFORMS),
         "Crypto selected SDK platform set")
    sdk_stems = {"ios": "iPhoneOS", "isimulator": "iPhoneSimulator",
                 "tvos": "AppleTVOS", "tvsimulator": "AppleTVSimulator",
                 "macos": "MacOSX"}
    for platform, row in value["platforms"].items():
        keys(row, "sdkRoot resolvedSDKRoot ar ranlib")
        stem = sdk_stems[platform]
        sdk_pattern = (r".*/" + re.escape(stem) +
                       r"\.platform/Developer/SDKs/" + re.escape(stem) +
                       r"(?:[0-9]{1,3}(?:\.[0-9]{1,3}){0,3})?\.sdk")
        for field in ("sdkRoot", "resolvedSDKRoot"):
            sdk = row[field]
            need(isinstance(sdk, str) and sdk.startswith("/") and "\x00" not in sdk and
                 ".." not in Path(sdk).parts and len(sdk) <= 4096 and
                 re.fullmatch(sdk_pattern, sdk) is not None,
                 "Crypto selected SDK root for " + platform)
        for name in ("ar", "ranlib"):
            tool = row[name]
            keys(tool, "selectedPath resolvedPath path bytes sha256")
            selected = tool["selectedPath"]
            need(isinstance(selected, str) and selected.startswith("/") and
                 Path(selected).name == name and len(selected) <= 4096 and
                 "\x00" not in selected and ".." not in Path(selected).parts,
                 "Crypto selected target archive tool")
            crypto_tool_record({key: tool[key] for key in
                                ("resolvedPath", "path", "bytes", "sha256")}, name)
            need(tool["path"] in resolved_aliases[name],
                 "Crypto selected SDK tool resolved basename: " + name)
    return value


def crypto_recipe_contract(work, library, platform, arch, sdk_tools):
    dist = work / "dist"
    prefix = dist / library / platform / "thin" / arch
    scratch = dist / library / platform / "scratch" / arch
    _, target_os, minimum, host_os = CRYPTO_PLATFORMS[platform]
    target_cpu = "x86_64" if arch == "x86_64" else "arm64"
    host = target_cpu + "-" + host_os + "-darwin"
    cflags = ["-arch", arch, "-isysroot", sdk_tools["sdkRoot"],
              "-target", target_cpu + "-apple-" + target_os, minimum]
    if platform in ("tvos", "tvsimulator"):
        cflags.append("-DHAVE_FORK=0")
    dependencies = () if library == "gmp" else ("gmp",) if library == "nettle" else ("gmp", "nettle")
    for dependency in dependencies:
        cflags.append("-I" + str(dist / dependency / platform / "thin" / arch / "include"))
    ldflags = ["-lc++", "-arch", arch, "-isysroot", sdk_tools["sdkRoot"],
               "-target", target_cpu + "-apple-" + target_os, minimum]
    for dependency in dependencies:
        ldflags.append("-L" + str(dist / dependency / platform / "thin" / arch / "lib"))
        if library != "gnutls":
            ldflags.append("-l" + dependency)
    flags = " ".join(cflags)
    environment = {
        "LC_CTYPE": "C", "CC": "/usr/bin/clang", "CXX": "/usr/bin/clang++",
        "CURRENT_ARCH": arch, "CFLAGS": flags + ' -O2', "CPPFLAGS": flags,
        "CXXFLAGS": flags + ' -O2', "ASMFLAGS": flags, "LDFLAGS": " ".join(ldflags),
        "PKG_CONFIG_LIBDIR": ":".join(str(dist / name / platform / "thin" / arch /
                                              "lib/pkgconfig") for name in CRYPTO_PKG_LIBRARIES) +
                                ":" + str(scratch / "vortx-sdk-pkgconfig"),
        "PKG_CONFIG_PATH": "", "PATH": CRYPTO_DEFAULT_PATH,
        "AR": sdk_tools["ar"]["selectedPath"],
        "RANLIB": sdk_tools["ranlib"]["selectedPath"],
        "CC_FOR_BUILD": "/usr/bin/clang", "MAKEFLAGS": "-j1",
        "CMAKE_BUILD_PARALLEL_LEVEL": "1", "CARGO_BUILD_JOBS": "1",
    }
    if library == "gmp":
        environment["ABI"] = "64"
    if library == "gnutls":
        gmp = str(dist / "gmp" / platform / "thin" / arch)
        nettle = str(dist / "nettle" / platform / "thin" / arch)
        environment.update(
            GMP_CFLAGS="-I" + gmp + "/include", GMP_LIBS="-L" + gmp + "/lib -lgmp",
            NETTLE_CFLAGS="-I" + nettle + "/include",
            NETTLE_LIBS="-L" + nettle + "/lib -lnettle",
            HOGWEED_CFLAGS="-I" + nettle + "/include",
            HOGWEED_LIBS="-L" + nettle + "/lib -lhogweed -lnettle -L" + gmp + "/lib -lgmp")
        if platform in ("tvos", "tvsimulator"):
            environment["ac_cv_func_fork"] = "no"
    return {
        "schema": 1, "library": library, "selector": CRYPTO_SELECTORS[library],
        "sourceDirectory": str(dist / (library + "-" + CRYPTO_SELECTORS[library])),
        "platform": platform, "arch": arch,
        "configureArguments": ["--prefix=" + str(prefix), *CRYPTO_CONFIGURE_FLAGS[library],
                               "--host=" + host],
        "makeArguments": list(CRYPTO_MAKE_ARGUMENTS), "environment": environment,
        "buildDirectory": str(scratch), "prefix": str(prefix),
        "compiled": True, "installed": True,
    }


def crypto_macro(text, name):
    values = re.findall(r"^\s*#\s*define\s+" + re.escape(name) +
                        r"\s+([0-9]+)\s*(?:/\*.*\*/)?\s*$", text, re.M)
    need(len(values) == 1, "Crypto expected one numeric macro " + name)
    return int(values[0])


def crypto_public_header(target, body):
    text = body.decode("utf-8", errors="strict")
    if target == "gmp":
        need(tuple(crypto_macro(text, key) for key in
                   ("__GNU_MP_VERSION", "__GNU_MP_VERSION_MINOR", "__GNU_MP_VERSION_PATCHLEVEL")) ==
             (6, 3, 0) and (crypto_macro(text, "GMP_LIMB_BITS"),
                            crypto_macro(text, "GMP_NAIL_BITS")) == (64, 0),
             "Mixed GMP public header version/ABI")
    elif target in ("nettle", "hogweed"):
        need(tuple(crypto_macro(text, key) for key in
                   ("NETTLE_VERSION_MAJOR", "NETTLE_VERSION_MINOR", "NETTLE_USE_MINI_GMP")) ==
             (4, 0, 0), "Mixed Nettle version or mini-GMP backend")
    elif target == "gnutls":
        need(tuple(crypto_macro(text, key) for key in
                   ("GNUTLS_VERSION_MAJOR", "GNUTLS_VERSION_MINOR", "GNUTLS_VERSION_PATCH")) ==
             (3, 8, 13) and
             len(re.findall(r'^\s*#\s*define\s+GNUTLS_VERSION\s+"3\.8\.13"\s*$', text, re.M)) == 1,
             "Mixed GnuTLS public header version")
    return body


def crypto_build_evidence(value, work, library, platform, arch, sdk_tools, budget):
    keys(value, "record generatedConfiguration installedConfiguration sdkMetadata")
    expected = crypto_recipe_contract(work, library, platform, arch, sdk_tools)
    scratch = Path(expected["buildDirectory"])
    record_path = (scratch / "vortx-crypto-build.json").relative_to(work).as_posix()
    record_body = crypto_inline_file(value["record"], 4 * MIB, record_path, budget)
    record = crypto_load(record_body)
    need(type(record) is dict and set(record) == set(expected) | {"generatedConfiguration"} and
         exact_equal({key: record[key] for key in expected}, expected),
         "Crypto configured build recipe differs from fixed policy")
    names = CRYPTO_GENERATED + CRYPTO_EXTRA_GENERATED[library]
    need(type(record["generatedConfiguration"]) is dict and
         set(record["generatedConfiguration"]) == set(names) and
         type(value["generatedConfiguration"]) is dict and
         set(value["generatedConfiguration"]) == set(names),
         "Crypto generated configuration set")
    generated = {}
    for name in names:
        expected_path = (scratch / name).relative_to(work).as_posix()
        body = crypto_inline_file(value["generatedConfiguration"][name], 16 * MIB,
                                  expected_path, budget)
        claimed = record["generatedConfiguration"][name]
        keys(claimed, "bytes sha256")
        need(exact_equal(claimed, {"bytes": len(body), "sha256": sha(body)}),
             "Crypto build record/generated raw bytes")
        generated[name] = body
    installed_spec = CRYPTO_INSTALLED_CONFIGURATION[library]
    need(type(value["installedConfiguration"]) is dict and
         set(value["installedConfiguration"]) == set(installed_spec.values()),
         "Crypto installed configuration set")
    installed = {}
    for generated_name, relative in installed_spec.items():
        expected_path = (Path(expected["prefix"]) / relative).relative_to(work).as_posix()
        body = crypto_inline_file(value["installedConfiguration"][relative], 16 * MIB,
                                  expected_path, budget)
        need(body == generated[generated_name],
             "Crypto installed configuration differs from generated raw bytes")
        installed[relative] = body
    need(type(value["sdkMetadata"]) is dict and
         set(value["sdkMetadata"]) == {"zlib.pc", "libxml-2.0.pc"},
         "Crypto SDK metadata set")
    for name in ("zlib.pc", "libxml-2.0.pc"):
        crypto_inline_file(value["sdkMetadata"][name], 4 * MIB,
                           (scratch / "vortx-sdk-pkgconfig" / name).relative_to(work).as_posix(),
                           budget)
    if library == "gmp":
        crypto_public_header("gmp", installed["include/gmp.h"])
    elif library == "nettle":
        crypto_public_header("nettle", installed["include/nettle/version.h"])
    else:
        crypto_public_header("gnutls", installed["include/gnutls/gnutls.h"])
    return installed, value["installedConfiguration"]


def crypto_normalize_symbols(text):
    symbols = set()
    for line in text.splitlines():
        value = line.strip()
        if not value or value.endswith(":"):
            continue
        need(re.fullmatch(r"[A-Za-z_.$][A-Za-z0-9_.$]*", value) is not None,
             "Unrecognized crypto nm row")
        symbols.add(value[1:] if value.startswith("_") else value)
    return symbols


def crypto_validate_symbols(observations):
    need(set(observations) == {item[0] for item in CRYPTO_LIBRARIES},
         "Crypto symbol library set")
    for target, required in CRYPTO_REQUIRED_SYMBOLS.items():
        need(required <= observations[target]["defined"],
             "Required defined crypto symbol missing from " + target)
    consumer = observations["Libsmbclient"]
    def helper(name):
        return name.startswith(("nettle_", "_nettle_", "hogweed_", "__gmp",
                                "gmp_", "mpz_", "mpn_", "mpq_", "mpf_"))
    need(not any(helper(name) for name in consumer["undefined"]),
         "Retained Samba directly imports a crypto-helper ABI")
    need(not any(name.startswith("_gnutls_") for name in consumer["undefined"]),
         "Retained Samba imports a private GnuTLS ABI")
    need(not any(name.startswith(("gnutls_", "_gnutls_")) or helper(name)
                 for name in consumer["defined"]),
         "Retained Samba embeds crypto provider symbols")
    imports = {name for name in consumer["undefined"] if name.startswith("gnutls_")} - consumer["defined"]
    need(imports, "Retained Samba has no observed public GnuTLS imports")
    need(not imports - observations["gnutls"]["defined"],
         "Selected GnuTLS does not define retained Samba imports")
    edges = {}
    for target in ("nettle", "hogweed", "gnutls"):
        required = {name for name in observations[target]["undefined"] if helper(name)} - observations[target]["defined"]
        providers = set().union(*(observations[name]["defined"]
                                  for name in ("gmp", "nettle", "hogweed") if name != target))
        need(not required - providers, target + " crypto-helper imports are unresolved")
        edges[target] = sorted(required)
    need(edges["gnutls"], "Selected GnuTLS has no observed crypto-helper linkage")
    return {"sambaGnuTLSImports": sorted(imports), "helperImports": edges}


def crypto_normalized_gmp_header(body):
    text = body.decode("utf-8", errors="strict")
    for name in ("__GMP_CC", "__GMP_CFLAGS"):
        definitions = re.findall(r"(?m)^[ \t]*#[ \t]*define[ \t]+" + name + r"\b[^\r\n]*$", text)
        pattern = (r"(?m)^[ \t]*#[ \t]*define[ \t]+" + name +
                   r'[ \t]+"(?:[^"\\\r\n]|\\[^\r\n])*"[ \t]*$')
        need(len(definitions) == 1 and len(re.findall(pattern, text)) == 1,
             "GMP diagnostic macro has an unapproved shape: " + name)
        text = re.sub(pattern, "#define " + name + ' "<generated-diagnostic>"', text)
    return text.encode("utf-8")


def crypto_header_correspondence(target, packaged, thin_evidence):
    if target != "gmp":
        need(all(packaged == body for _, body, _ in thin_evidence),
             "Packaged crypto header differs from selected thin build bytes")
        return {"kind": "exact-checked-header-bytes"}
    normalized = crypto_normalized_gmp_header(packaged)
    matches = []
    for identity, body, row in thin_evidence:
        if crypto_normalized_gmp_header(body) == normalized:
            if body == packaged:
                matches.append({"platform": identity[0], "arch": identity[1], "header": row})
        else:
            need(False, "GMP thin headers differ beyond generated compiler diagnostics")
    need(matches, "Packaged GMP header is not one exact selected thin header")
    return {"kind": "gmp-two-generated-diagnostic-strings-only",
            "normalizedSHA256": sha(normalized), "packagedHeaderFrom": matches}


def crypto_zip_file(catalog, target, name, limit=512 * MIB):
    body, rows = catalog[target]
    with io.BytesIO(body) as stream, zip_open(stream, 100000) as archive:
        _, data = _openssl_archive_member(archive, rows, name, limit)
    return data


def crypto_zip_catalog(zip_bodies, libraries=None):
    if libraries is None:
        libraries = CRYPTO_LIBRARIES
    expected_targets = {row[0] for row in libraries}
    need(set(zip_bodies) == expected_targets, "Retained crypto ZIP body set")
    expected_slices = {slice_name for _, _, slice_name in CRYPTO_MATRIX}
    expected_arches = {slice_name: sorted({arch for _, arch, candidate in CRYPTO_MATRIX
                                          if candidate == slice_name})
                       for slice_name in expected_slices}
    catalog = {}
    for target, _, _, binary_name in libraries:
        body = zip_bodies[target]
        with io.BytesIO(body) as stream, zip_open(stream, 100000) as archive:
            rows = zip_index(archive, count=100000, total=4 * 1024**3)
            root = target + ".xcframework"
            need(rows and all(name.startswith(root + "/") for name in rows),
                 "Crypto ZIP root")
            need(all((name.removeprefix(root + "/") == "Info.plist" or
                      name.removeprefix(root + "/").split("/", 1)[0] in expected_slices)
                     for name in rows),
                 "Crypto ZIP has an undeclared top-level slice")
            info_name = root + "/Info.plist"
            _, info_body = _openssl_archive_member(archive, rows, info_name, 4 * MIB)
            metadata = plistlib.loads(info_body)
        need(isinstance(metadata, dict) and metadata.get("CFBundlePackageType") == "XFWK" and
             metadata.get("XCFrameworkFormatVersion") == "1.0",
             "Crypto XCFramework metadata identity")
        available = metadata.get("AvailableLibraries")
        need(isinstance(available, list) and len(available) == len(expected_slices),
             "Crypto XCFramework slice declarations")
        declarations = set()
        for item in available:
            need(isinstance(item, dict), "Crypto XCFramework declaration shape")
            identifier = item.get("LibraryIdentifier")
            need(isinstance(identifier, str) and identifier in expected_slices and
                 identifier not in declarations, "Crypto XCFramework declaration identity")
            platform = "macos" if identifier.startswith("macos-") else (
                "tvos" if identifier.startswith("tvos-") else "ios")
            expected = {"LibraryIdentifier": identifier,
                        "LibraryPath": binary_name + ".framework",
                        "SupportedArchitectures": expected_arches[identifier],
                        "SupportedPlatform": platform}
            if identifier.endswith("-simulator"):
                expected["SupportedPlatformVariant"] = "simulator"
            actual = dict(item)
            need(isinstance(actual.get("SupportedArchitectures"), list) and
                 all(isinstance(value, str) for value in actual["SupportedArchitectures"]),
                 "Crypto XCFramework architecture list")
            actual["SupportedArchitectures"] = sorted(actual["SupportedArchitectures"])
            need(exact_equal(actual, expected), "Crypto XCFramework declaration differs")
            declarations.add(identifier)
        need(declarations == expected_slices, "Crypto XCFramework declaration coverage")
        expected_links = {}
        framework = root + "/macos-arm64_x86_64/" + binary_name + ".framework"
        for name, destination in (("Versions/Current", "A"),
                                  (binary_name, "Versions/Current/" + binary_name),
                                  ("Resources", "Versions/Current/Resources")):
            expected_links[framework + "/" + name] = destination
        actual_links = {name: row["target"] for name, row in rows.items()
                        if row["kind"] == "symlink"}
        need(actual_links == expected_links, "Crypto exact macOS framework link set")
        catalog[target] = (body, rows)
    return catalog


def crypto_plain_row(row, expected_path=None, maximum=512 * MIB):
    keys(row, "path bytes sha256")
    name = path(row["path"])
    need(expected_path is None or name == expected_path, "Crypto recorded file path")
    integer(row["bytes"], maximum)
    need(row["bytes"] > 0, "Crypto recorded file is empty")
    digest(row["sha256"])
    return row


def crypto_zip_row(catalog, target, package_path):
    prefix = "artifacts/" + target + ".xcframework/"
    need(package_path.startswith(prefix), "Crypto packaged path root")
    archive_name = target + ".xcframework/" + package_path.removeprefix(prefix)
    row = catalog[target][1].get(archive_name)
    need(isinstance(row, dict) and row.get("kind") == "file",
         "Crypto packaged regular file missing from original ZIP")
    return {"path": package_path, "bytes": row["bytes"], "sha256": row["sha256"]}, archive_name


def crypto_framework_layout(target, binary_name, slice_name, catalog):
    if not slice_name.startswith("macos-"):
        return {"kind": "shallow"}
    package_framework = ("artifacts/" + target + ".xcframework/" + slice_name + "/" +
                         binary_name + ".framework")
    archive_framework = (target + ".xcframework/" + slice_name + "/" +
                         binary_name + ".framework")
    links = []
    for name, destination in (("Versions/Current", "A"),
                              (binary_name, "Versions/Current/" + binary_name),
                              ("Resources", "Versions/Current/Resources")):
        row = catalog[target][1].get(archive_framework + "/" + name)
        body = destination.encode("utf-8")
        need(isinstance(row, dict) and row.get("kind") == "symlink" and
             row.get("target") == destination and row.get("bytes") == len(body) and
             row.get("sha256") == sha(body), "Crypto macOS framework link bytes")
        links.append({"path": package_framework + "/" + name, "target": destination,
                      "bytes": len(body), "sha256": sha(body)})
    info_path = package_framework + "/Versions/A/Resources/Info.plist"
    info, _ = crypto_zip_row(catalog, target, info_path)
    return {"kind": "fixed-macos-versions-A", "links": links, "info": info}


def crypto_reader_caps(value):
    def reader_bytes(item):
        if isinstance(item, dict):
            if "text" in item:
                crypto_recorded_text(item, "native reader")
                return len(json.dumps(item, sort_keys=True).encode("utf-8"))
            return sum(reader_bytes(child) for child in item.values())
        if isinstance(item, list):
            return sum(reader_bytes(child) for child in item)
        return 0
    def metadata(item):
        if isinstance(item, dict):
            return {key: metadata(child) for key, child in item.items()
                    if key not in ("bodyBase64", "text")}
        if isinstance(item, list):
            return [metadata(child) for child in item]
        return item
    need(reader_bytes(value) <= CRYPTO_MAX_READER_JSON, "Crypto aggregate reader JSON cap")
    need(len(json.dumps(metadata(value), indent=2, sort_keys=True).encode("utf-8")) <=
         CRYPTO_MAX_METADATA_JSON, "Crypto receipt metadata JSON cap")


def crypto_chain_receipt(body, zip_bodies, archive_sources,
                         candidate_package_row, candidate_package_body):
    """Validate the frozen gate receipt against retained raw artifact bytes."""
    need(isinstance(body, bytes) and 0 < len(body) <= CRYPTO_MAX_RECEIPT,
         "Crypto receipt raw byte bound")
    value = crypto_load(body)
    need(type(value) is dict, "Crypto receipt object")
    keys(value, "schemaVersion profile work packagePolicy inlineBodyPolicy versions sourcePins "
                "tools packageManifest xcframeworkInfo releaseSourceBoundary rows acceptance openGates")
    expected_identity = {
        "schemaVersion": 2, "profile": CRYPTO_CHAIN_PROFILE,
        "packagePolicy": CRYPTO_PACKAGE_POLICY,
        "inlineBodyPolicy": CRYPTO_INLINE_BODY_POLICY,
        "versions": CRYPTO_VERSIONS, "sourcePins": CRYPTO_SOURCE_PINS,
        "acceptance": CRYPTO_ACCEPTANCE, "openGates": list(CRYPTO_OPEN_GATES),
    }
    need(all(exact_equal(value[key], expected) for key, expected in expected_identity.items()),
         "Crypto receipt fixed identity")
    work_text = value["work"]
    need(type(work_text) is str and 0 < len(work_text) <= 4096 and
         work_text.startswith("/") and "\x00" not in work_text,
         "Crypto receipt WORK path")
    work = Path(work_text)
    need(work.is_absolute() and str(work) == work_text and ".." not in work.parts,
         "Crypto receipt normalized WORK path")

    tools = crypto_tools(value["tools"])
    catalog = crypto_zip_catalog(zip_bodies)

    need(type(candidate_package_row) is dict and
         candidate_package_row.get("kind") == "file" and
         candidate_package_row.get("bytes") == len(candidate_package_body) and
         candidate_package_row.get("sha256") == sha(candidate_package_body),
         "Crypto candidate Package.swift raw bytes")
    package_manifest = {"path": "Package.swift", "bytes": len(candidate_package_body),
                        "sha256": sha(candidate_package_body)}
    crypto_plain_row(value["packageManifest"], "Package.swift", 4 * MIB)
    need(exact_equal(value["packageManifest"], package_manifest),
         "Crypto package manifest/raw candidate correspondence")

    need(type(value["xcframeworkInfo"]) is dict and
         set(value["xcframeworkInfo"]) == {item[0] for item in CRYPTO_LIBRARIES},
         "Crypto XCFramework metadata target set")
    for target, _, _, _ in CRYPTO_LIBRARIES:
        expected, _ = crypto_zip_row(
            catalog, target, "artifacts/" + target + ".xcframework/Info.plist")
        crypto_plain_row(value["xcframeworkInfo"][target], expected["path"], 4 * MIB)
        need(exact_equal(value["xcframeworkInfo"][target], expected),
             "Crypto XCFramework metadata/raw ZIP correspondence")

    need(type(archive_sources) is dict and
         type(archive_sources.get("capture")) is dict and
         type(archive_sources["capture"].get("receipt")) is dict,
         "Crypto release-source boundary metadata")
    source_receipt = archive_sources["capture"]["receipt"]
    release_boundary = {
        "path": "dist/crypto-sources/receipt.json",
        "bytes": source_receipt["bytes"], "sha256": source_receipt["sha256"],
    }
    crypto_plain_row(value["releaseSourceBoundary"], release_boundary["path"],
                     CRYPTO_MAX_RECEIPT)
    need(exact_equal(value["releaseSourceBoundary"], release_boundary),
         "Crypto gate/source-helper receipt correspondence")

    rows = value["rows"]
    need(type(rows) is list and len(rows) == len(CRYPTO_MATRIX),
         "Crypto exact nine-row matrix")
    expected_matrix = list(CRYPTO_MATRIX)
    observed_matrix = []
    build_evidence = {}
    inline_budget = [0]
    for row in rows:
        keys(row, "platform arch slice libraries builds sambaGnuTLSImports helperImports")
        identity = (row["platform"], row["arch"], row["slice"])
        observed_matrix.append(identity)
        need(identity in CRYPTO_MATRIX and identity not in build_evidence,
             "Crypto matrix row identity")
        need(type(row["builds"]) is dict and
             set(row["builds"]) == {"gmp", "nettle", "gnutls"},
             "Crypto build family set")
        platform, arch, _ = identity
        sdk_tools = tools["platforms"][platform]
        build_evidence[identity] = {}
        for library in ("gmp", "nettle", "gnutls"):
            bodies, recorded_rows = crypto_build_evidence(
                row["builds"][library], work, library, platform, arch,
                sdk_tools, inline_budget)
            build_evidence[identity][library] = {
                "bodies": bodies, "rows": recorded_rows,
            }
    need(observed_matrix == expected_matrix,
         "Crypto matrix order/coverage differs from frozen gate")

    expected_slice_arches = {
        slice_name: sorted({arch for _, arch, candidate in CRYPTO_MATRIX
                            if candidate == slice_name})
        for _, _, slice_name in CRYPTO_MATRIX
    }
    library_map = {target: (directory, archive_name, binary_name)
                   for target, directory, archive_name, binary_name in CRYPTO_LIBRARIES}

    def plain_inline(row):
        keys(row, "path bytes sha256 bodyBase64")
        return {key: row[key] for key in ("path", "bytes", "sha256")}

    def thin_header_material(identity, target):
        platform, arch, _ = identity
        if target == "Libsmbclient":
            rows = [
                {"path": ("dist/libsmbclient/" + platform + "/thin/" + arch +
                          "/include/samba-4.0/" + name),
                 "bytes": size, "sha256": checksum}
                for name, (size, checksum) in CRYPTO_SMB_HEADERS.items()
            ]
            return rows, []
        source = "nettle" if target == "hogweed" else target
        relative = {"gmp": "include/gmp.h",
                    "nettle": "include/nettle/version.h",
                    "hogweed": "include/nettle/version.h",
                    "gnutls": "include/gnutls/gnutls.h"}[target]
        evidence = build_evidence[identity][source]
        return ([plain_inline(evidence["rows"][relative])],
                [evidence["bodies"][relative]])

    for row in rows:
        platform, arch, slice_name = row["platform"], row["arch"], row["slice"]
        identity = (platform, arch, slice_name)
        libraries = row["libraries"]
        need(type(libraries) is dict and set(libraries) == set(library_map),
             "Crypto row library set")
        observations = {}
        for target, library in libraries.items():
            keys(library, "version thin thinHeaders packaged packagedHeaders correspondence "
                          "frameworkLayout headerCorrespondence architectures defined undefined")
            need(type(library["version"]) is str and
                 library["version"] == CRYPTO_VERSIONS[target],
                 "Crypto library version: " + target)
            directory, archive_name, binary_name = library_map[target]
            thin_path = ("dist/" + directory + "/" + platform + "/thin/" + arch +
                         "/lib/" + archive_name)
            thin = crypto_plain_row(library["thin"], thin_path)
            if target == "Libsmbclient":
                need((thin["bytes"], thin["sha256"]) ==
                     CRYPTO_SMB_PINS[platform + "/" + arch],
                     "Retained Samba thin archive identity")

            framework = ("artifacts/" + target + ".xcframework/" + slice_name + "/" +
                         binary_name + ".framework")
            packaged_path = (framework + "/Versions/A/" + binary_name
                             if slice_name.startswith("macos-") else
                             framework + "/" + binary_name)
            packaged_expected, packaged_archive_name = crypto_zip_row(
                catalog, target, packaged_path)
            packaged = crypto_plain_row(library["packaged"], packaged_path)
            need(exact_equal(packaged, packaged_expected),
                 "Crypto packaged binary/raw ZIP correspondence")
            packaged_body = crypto_zip_file(catalog, target, packaged_archive_name)
            need((len(packaged_body), sha(packaged_body)) ==
                 (packaged["bytes"], packaged["sha256"]),
                 "Crypto packaged binary body identity")
            segments = _macho_arch_hashes(packaged_body)
            slice_arches = expected_slice_arches[slice_name]
            if segments is None:
                need(packaged_body.startswith(b"!<arch>\n") and len(slice_arches) == 1,
                     "Crypto one-arch package must be an ar body or a parsed FAT container")
                segments = {slice_arches[0]: (len(packaged_body), sha(packaged_body))}
            need(set(segments) == set(slice_arches),
                 "Crypto exact packaged architecture set")
            segment = {"bytes": segments[arch][0], "sha256": segments[arch][1]}
            keys(library["correspondence"], "bytes sha256")
            need(exact_equal(library["correspondence"], segment) and
                 exact_equal(segment, {"bytes": thin["bytes"], "sha256": thin["sha256"]}),
                 "Crypto packaged/thin archive segment correspondence")

            architectures = crypto_recorded_text(library["architectures"], "architecture")
            need(sorted(architectures.split()) == slice_arches,
                 "Crypto recorded architecture set")
            defined = crypto_normalize_symbols(
                crypto_recorded_text(library["defined"], "defined symbols"))
            undefined = crypto_normalize_symbols(
                crypto_recorded_text(library["undefined"], "undefined symbols"))
            observations[target] = {"defined": defined, "undefined": undefined}

            expected_thin_headers, thin_bodies = thin_header_material(identity, target)
            need(type(library["thinHeaders"]) is list and
                 len(library["thinHeaders"]) == len(expected_thin_headers),
                 "Crypto thin header count")
            for reported, expected in zip(library["thinHeaders"],
                                          expected_thin_headers, strict=True):
                crypto_plain_row(reported, expected["path"], 4 * MIB)
                need(exact_equal(reported, expected),
                     "Crypto thin header/build evidence correspondence")

            header_names = ({"gmp": ("gmp.h",),
                             "nettle": ("version.h",),
                             "hogweed": ("nettle/version.h",),
                             "gnutls": ("gnutls.h",),
                             "Libsmbclient": tuple(CRYPTO_SMB_HEADERS)}[target])
            expected_packaged_headers, packaged_header_bodies = [], []
            for header_name in header_names:
                header_path = framework + "/Headers/" + (
                    "samba-4.0/" + header_name if target == "Libsmbclient" else header_name)
                expected_header, zip_name = crypto_zip_row(catalog, target, header_path)
                header_body = crypto_zip_file(catalog, target, zip_name, 4 * MIB)
                expected_packaged_headers.append(expected_header)
                packaged_header_bodies.append(header_body)
                if target == "Libsmbclient":
                    size, checksum = CRYPTO_SMB_HEADERS[header_name]
                    need((len(header_body), sha(header_body)) == (size, checksum),
                         "Retained Samba packaged public header identity")
                else:
                    crypto_public_header(target, header_body)
            need(type(library["packagedHeaders"]) is list and
                 len(library["packagedHeaders"]) == len(expected_packaged_headers),
                 "Crypto packaged header count")
            for reported, expected in zip(library["packagedHeaders"],
                                          expected_packaged_headers, strict=True):
                crypto_plain_row(reported, expected["path"], 4 * MIB)
                need(exact_equal(reported, expected),
                     "Crypto packaged header/raw ZIP correspondence")

            if target == "gmp":
                thin_evidence = []
                for candidate in CRYPTO_MATRIX:
                    if candidate[2] != slice_name:
                        continue
                    candidate_rows, candidate_bodies = thin_header_material(candidate, target)
                    thin_evidence.append(((candidate[0], candidate[1]),
                                          candidate_bodies[0], candidate_rows[0]))
                expected_headers = crypto_header_correspondence(
                    target, packaged_header_bodies[0], thin_evidence)
            elif target == "Libsmbclient":
                expected_headers = {"kind": "exact-checked-header-bytes"}
            else:
                expected_headers = crypto_header_correspondence(
                    target, packaged_header_bodies[0],
                    [(identity[:2], thin_bodies[0], expected_thin_headers[0])])
            need(exact_equal(library["headerCorrespondence"], expected_headers),
                 "Crypto public-header correspondence policy")
            expected_layout = crypto_framework_layout(
                target, binary_name, slice_name, catalog)
            need(exact_equal(library["frameworkLayout"], expected_layout),
                 "Crypto framework layout/raw ZIP correspondence")

        symbol_policy = crypto_validate_symbols(observations)
        need(exact_equal(row["sambaGnuTLSImports"],
                         symbol_policy["sambaGnuTLSImports"]) and
             exact_equal(row["helperImports"], symbol_policy["helperImports"]),
             "Crypto symbol-boundary receipt")

    need(inline_budget[0] <= CRYPTO_MAX_INLINE_RAW,
         "Crypto aggregate inline raw-body cap")
    crypto_reader_caps(value)
    canonical = (json.dumps(value, indent=2, sort_keys=True) + "\n").encode("utf-8")
    need(body == canonical and len(canonical) <= CRYPTO_MAX_RECEIPT,
         "Crypto canonical final receipt bytes")
    return value


def subtitle_inline(row, label, budget, maximum=SUBTITLE_MAX_BODY):
    keys(row, "bytes sha256 bodyBase64")
    count, encoded = row["bytes"], row["bodyBase64"]
    need(type(count) is int and 0 < count <= maximum and
         isinstance(encoded, str) and
         len(encoded) <= ((maximum + 2) // 3) * 4,
         "Subtitle inline-body bound: " + label)
    digest(row["sha256"])
    try:
        body = base64.b64decode(encoded.encode("ascii"), validate=True)
    except (UnicodeEncodeError, binascii.Error) as error:
        raise ValueError("Subtitle inline body is not canonical base64: " + label) from error
    need(base64.b64encode(body).decode("ascii") == encoded and
         len(body) == count and sha(body) == row["sha256"],
         "Subtitle inline raw-body identity: " + label)
    budget[0] += len(body)
    need(budget[0] <= SUBTITLE_MAX_INLINE_RAW,
         "Subtitle aggregate raw-body cap")
    return body


def subtitle_text(body, label):
    text = body.decode("utf-8", errors="strict")
    need(text and "\x00" not in text, "Subtitle bounded text: " + label)
    return text


def subtitle_platform(platform, arch):
    sdk_stem = {"ios": "iPhoneOS", "isimulator": "iPhoneSimulator",
                "tvos": "AppleTVOS", "tvsimulator": "AppleTVSimulator",
                "macos": "MacOSX"}[platform]
    cpu = "x86_64" if arch == "x86_64" else "arm64"
    target = {"ios": cpu + "-apple-ios15.0",
              "isimulator": cpu + "-apple-ios15.0-simulator",
              "tvos": cpu + "-apple-tvos15.0",
              "tvsimulator": cpu + "-apple-tvos15.0-simulator",
              "macos": cpu + "-apple-macos12.0"}[platform]
    minimum = {"ios": "-mios-version-min=15.0",
               "isimulator": "-mios-simulator-version-min=15.0",
               "tvos": "-mtvos-version-min=15.0",
               "tvsimulator": "-mtvos-simulator-version-min=15.0",
               "macos": "-mmacosx-version-min=12.0"}[platform]
    host_cpu = "aarch64" if cpu == "arm64" else cpu
    host = host_cpu + "-" + {"ios": "ios", "isimulator": "ios",
                         "tvos": "tvos", "tvsimulator": "tvos",
                         "macos": "apple"}[platform] + "-darwin"
    subsystem = {"ios": "ios", "isimulator": "ios-simulator",
                 "tvos": "tvos", "tvsimulator": "tvos-simulator",
                 "macos": "macos"}[platform]
    cpu_family = "x86_64" if arch == "x86_64" else "aarch64"
    return sdk_stem, target, minimum, host, subsystem, cpu_family, cpu


def subtitle_environment(value, work, library, platform, arch):
    expected_keys = {"LC_CTYPE", "MAKEFLAGS", "CMAKE_BUILD_PARALLEL_LEVEL",
                     "CARGO_BUILD_JOBS", "CC", "CXX", "CURRENT_ARCH", "CFLAGS",
                     "CPPFLAGS", "CXXFLAGS", "ASMFLAGS", "LDFLAGS",
                     "PKG_CONFIG_LIBDIR", "PKG_CONFIG_PATH", "PATH"}
    need(type(value) is dict and set(value) == expected_keys and
         all(isinstance(item, str) and len(item) <= 65536 and "\x00" not in item
             for item in value.values()),
         "Subtitle environment keys/text differ from BaseBuild")
    sdk_stem, target, minimum, _, _, _, _ = subtitle_platform(platform, arch)
    prefix = "-arch " + arch + " -isysroot "
    suffix = " -target " + target + " " + minimum
    fork = " -DHAVE_FORK=0" if platform in ("tvos", "tvsimulator") else ""
    freetype = work / 'dist/libfreetype' / platform / 'thin' / arch
    dependency_cflags = ' -I' + str(freetype / 'include') if library == 'libbluray' else ''
    cflags = value["CFLAGS"]
    optimization = ' -O2' if library == 'libunibreak' else ''
    if optimization:
        need(cflags.endswith(optimization) and
             [item for item in cflags.split() if item.startswith('-O')] == ['-O2'],
             'Unibreak shipping CFLAGS require exactly one trailing -O2')
        cflags = cflags[:-len(optimization)]
    need(cflags.startswith(prefix) and cflags.endswith(suffix + fork + dependency_cflags),
         "Subtitle C flags differ from fixed platform policy")
    sdk_root = cflags[len(prefix):len(cflags) - len(suffix + fork + dependency_cflags)]
    sdk_pattern = (r".*/" + re.escape(sdk_stem) +
                   r"\.platform/Developer/SDKs/" + re.escape(sdk_stem) +
                   r"(?:[0-9]{1,3}(?:\.[0-9]{1,3}){0,3})?\.sdk")
    need(sdk_root.startswith("/") and "\x00" not in sdk_root and
         ".." not in Path(sdk_root).parts and
         re.fullmatch(sdk_pattern, sdk_root) is not None,
         "Subtitle SDK root differs from fixed platform")
    build = work / "dist" / library / platform / "scratch" / arch
    pkg_roots = [str(work / "dist" / name / platform / "thin" / arch /
                     "lib/pkgconfig") for name in OPENSSL_PKG_LIBRARIES]
    pkg_roots.append(str(build / "vortx-sdk-pkgconfig"))
    if library == "libfreetype":
        pkg_roots = [str(build / "vortx-sdk-pkgconfig")]
    expected = {"LC_CTYPE": "C", "MAKEFLAGS": "-j1",
                "CMAKE_BUILD_PARALLEL_LEVEL": "1", "CARGO_BUILD_JOBS": "1",
                "CC": "/usr/bin/clang", "CXX": "/usr/bin/clang++",
                "CURRENT_ARCH": arch, "CFLAGS": cflags + optimization, "CPPFLAGS": cflags,
                "CXXFLAGS": cflags + optimization, "ASMFLAGS": cflags,
                "LDFLAGS": "-lc++ " + prefix + sdk_root + suffix +
                           ((' -L' + str(freetype / 'lib') + ' -lfreetype') if library == 'libbluray' else ''),
                "PKG_CONFIG_LIBDIR": ":".join(pkg_roots), "PKG_CONFIG_PATH": "",
                "PATH": OPENSSL_DEFAULT_PATH}
    need(exact_equal(value, expected),
         "Subtitle environment differs from exact BaseBuild output")
    return sdk_root, cflags, expected["LDFLAGS"]


def subtitle_meson_cross(body, work, library, platform, arch,
                         sdk_root, cflags, ldflags):
    text = subtitle_text(body, "Meson cross file")
    tools = {}
    for name in ("ar", "strip"):
        matches = re.findall(r"^" + name + r" = '([^']+)'$", text, re.M)
        need(len(matches) == 1 and matches[0].startswith("/") and
             ".." not in Path(matches[0]).parts and "\x00" not in matches[0] and
             Path(matches[0]).name == name and len(matches[0]) <= 4096,
             "Subtitle Meson cross-file SDK tool: " + name)
        tools[name] = matches[0]
    _, _, _, _, subsystem, cpu_family, cpu = subtitle_platform(platform, arch)
    quoted_c = ", ".join("'" + item + "'" for item in cflags.split(" "))
    quoted_ld = ", ".join("'" + item + "'" for item in ldflags.split(" "))
    expected = """[binaries]
c = '/usr/bin/clang'
cpp = '/usr/bin/clang++'
objc = '/usr/bin/clang'
objcpp = '/usr/bin/clang++'
ar = '{ar}'
strip = '{strip}'
pkg-config = 'pkg-config'

[properties]
has_function_printf = true
has_function_hfkerhisadf = false

[host_machine]
system = 'darwin'
subsystem = '{subsystem}'
kernel = 'xnu'
cpu_family = '{cpu_family}'
cpu = '{cpu}'
endian = 'little'

[built-in options]
default_library = 'static'
buildtype = 'release'
prefix = '{prefix}'
c_args = [{cflags}]
cpp_args = [{cflags}]
objc_args = [{cflags}]
objcpp_args = [{cflags}]
c_link_args = [{ldflags}]
cpp_link_args = [{ldflags}]
objc_link_args = [{ldflags}]
objcpp_link_args = [{ldflags}]""".format(
        ar=tools["ar"], strip=tools["strip"], subsystem=subsystem,
        cpu_family=cpu_family, cpu=cpu,
        prefix=work / "dist" / library / platform / "thin" / arch,
        cflags=quoted_c, ldflags=quoted_ld)
    need(text.rstrip("\n") == expected,
         "Subtitle Meson cross file differs from BaseBuild")


def subtitle_build_options(body, library, prefix):
    value = crypto_load(body)
    need(type(value) is list and len(value) <= 10000,
         "Subtitle Meson build-option set is unbounded")
    options = {}
    for row in value:
        need(type(row) is dict and isinstance(row.get("name"), str) and
             row["name"] not in options,
             "Subtitle Meson build-option row is malformed or duplicate")
        options[row["name"]] = row.get("value")
    expected = {"default_library": "static", "buildtype": "release",
                "prefix": str(prefix)}
    for argument in SUBTITLE_ARGUMENTS[library]:
        if argument == "--wrap-mode=nodownload":
            expected["wrap_mode"] = "nodownload"
        elif argument == '--force-fallback-for=libudfread':
            expected['force_fallback_for'] = ['libudfread']
        else:
            name, raw = argument.removeprefix("-D").split("=", 1)
            expected[name] = {"true": True, "false": False}.get(raw, raw)
    need(all(name in options and exact_equal(options[name], item)
             for name, item in expected.items()),
         "Subtitle Meson effective options differ from fixed arguments")


def subtitle_dependencies(body):
    value = crypto_load(body)
    need(type(value) is list and len(value) <= 10000,
         "Subtitle Meson dependency set is unbounded")
    text = json.dumps(value, sort_keys=True, separators=(",", ":")).casefold()
    forbidden = ("freetype", "glib", "gobject", "cairo", "chafa", "libpng",
                 "zlib", "icu", "graphite2", "fontations", "harfrust", "kbts",
                 "wrapdb")
    need(not any(re.search(r"(?<![a-z0-9_])" + re.escape(name) +
                           r"(?![a-z0-9_])", text) for name in forbidden),
         "Subtitle Meson dependency closure admits a disabled integration")


def subtitle_compile_command(row, arch, sdk_root, target, minimum, fribidi_role=None):
    need(type(row) is dict and 0 < len(row) <= 16 and
         all(isinstance(name, str) and name and len(name) <= 128 for name in row),
         "Subtitle compile-command row is malformed or unbounded")
    payloads = []
    if "arguments" in row:
        arguments = row["arguments"]
        need(type(arguments) is list and 0 < len(arguments) <= 16384 and
             all(isinstance(item, str) and item and len(item) <= 65536 and
                 "\x00" not in item for item in arguments) and
             sum(len(item) for item in arguments) <= 1024 * 1024,
             "Subtitle compile-command arguments are malformed or unbounded")
        payloads.append(arguments)
    if "command" in row:
        command = row["command"]
        need(isinstance(command, str) and command and len(command) <= 1024 * 1024 and
             "\x00" not in command,
             "Subtitle compile-command text is malformed or unbounded")
        try:
            arguments = shlex.split(command, posix=True)
        except ValueError as error:
            raise ValueError("Subtitle compile-command text is not shell-tokenizable") from error
        need(arguments and len(arguments) <= 16384 and
             all(item and len(item) <= 65536 for item in arguments),
             "Subtitle compile-command token set is malformed or unbounded")
        payloads.append(arguments)
    need(payloads, "Subtitle compile-command row has no command payload")
    for arguments in payloads:
        alternate = [item for item in arguments
                     if ((item.startswith("-target") and item != "-target")
                         or item.startswith("--target")
                         or (item.startswith("-isysroot") and item != "-isysroot")
                         or item.startswith("--sysroot"))]
        need(not alternate,
             "Subtitle compile-command has an alternate target/sysroot spelling")

        def values(flag):
            indexes = [index for index, item in enumerate(arguments) if item == flag]
            need(all(index + 1 < len(arguments) for index in indexes),
                 "Subtitle compile-command has an unterminated target flag")
            return [arguments[index + 1] for index in indexes]

        deployment = [item for item in arguments if re.fullmatch(
            r"-(?:mios|mios-simulator|mtvos|mtvos-simulator|mmacosx)-version-min=.*",
            item)]
        arch_values = values("-arch")
        sdk_values = values("-isysroot")
        target_values = values("-target")
        if fribidi_role is not None:
            source, output, native = fribidi_role
            need(arguments[0] == ("cc" if native else "/usr/bin/clang") and
                 not any((item.startswith("-o") and item != "-o") or
                         item.startswith("--output") or item.startswith("@") or item == "--"
                         for item in arguments) and
                 values("-c") == [source] and values("-o") == [output] and
                 [item for item in arguments
                  if not item.startswith("-") and item.endswith(".c")] == [source],
                 "FriBidi compile-command compiler/source/output differs from its fixed role")
            if native:
                toggles = [item for item in arguments if re.match(
                    r"^-[DU](?:HAVE_CONFIG_H|HAVE_STRINGIZE|DONT_HAVE_FRIBIDI_CONFIG_H)(?:=|$)", item)]
                need(not arch_values and not sdk_values and not target_values and not deployment and
                     not any(item.startswith("-arch") for item in arguments) and
                     not any(item in ("-D", "-U") or
                             (item.startswith(("-D", "-U")) and any(char.isspace() for char in item))
                             for item in arguments) and
                     not any(item.startswith(("-Wp,", "-Xpreprocessor", "-Xclang"))
                             for item in arguments) and
                     sorted(toggles) == sorted([
                         "-UHAVE_CONFIG_H", "-DHAVE_STRINGIZE", "-DDONT_HAVE_FRIBIDI_CONFIG_H"]),
                     "FriBidi native generator has shipping target flags or changed configuration defines")
                continue
        need(arch_values and all(item == arch for item in arch_values) and
             sdk_values and all(item == sdk_root for item in sdk_values) and
             target_values and all(item == target for item in target_values) and
             deployment and all(item == minimum for item in deployment),
             "Subtitle compile-command target flags differ from fixed policy")


def subtitle_fribidi_compile_commands(commands, build, arch, sdk_root, target, minimum):
    # Exact pinned 1.0.17 gen.tab/meson.build: 1 + 6*2 native objects.
    root = "../../../../libfribidi-1.0.17-6949dcde/"
    expected = {}
    for program in ("gen-unicode-version", "gen-bidi-type-tab",
                    "gen-joining-type-tab", "gen-arabic-shaping-tab",
                    "gen-mirroring-tab", "gen-brackets-tab", "gen-brackets-type-tab"):
        names = (program + ".c",) if program == "gen-unicode-version" else (program + ".c", "packtab.c")
        for name in names:
            expected[(root + "gen.tab/" + name, "gen.tab/" + program + ".p/" + name + ".o")] = True
    # Pinned lib/meson.build's complete shipping source list (deprecated=true).
    for name in ("fribidi.c", "fribidi-arabic.c", "fribidi-bidi.c", "fribidi-bidi-types.c",
                 "fribidi-char-sets.c", "fribidi-char-sets-cap-rtl.c",
                 "fribidi-char-sets-cp1255.c", "fribidi-char-sets-cp1256.c",
                 "fribidi-char-sets-iso8859-6.c", "fribidi-char-sets-iso8859-8.c",
                 "fribidi-char-sets-utf8.c", "fribidi-deprecated.c", "fribidi-joining.c",
                 "fribidi-joining-types.c", "fribidi-mirroring.c", "fribidi-brackets.c",
                 "fribidi-run.c", "fribidi-shape.c"):
        expected[(root + "lib/" + name, "lib/libfribidi.a.p/" + name + ".o")] = False
    need(type(commands) is list and len(commands) == len(expected),
         "FriBidi compile-command set must contain exactly 13 native and 18 shipping rows")
    seen = set()
    for row in commands:
        need(type(row) is dict and {"directory", "file", "output"} <= set(row) and
             not set(row) - {"directory", "file", "output", "command", "arguments"} and
             isinstance(row["file"], str) and isinstance(row["output"], str) and
             row["directory"] == str(build),
             "FriBidi compile-command metadata differs from the fixed build directory/schema")
        identity = (row["file"], row["output"])
        need(identity in expected and identity not in seen,
             "FriBidi compile-command has an unknown or duplicate source/output role")
        seen.add(identity)
        subtitle_compile_command(row, arch, sdk_root, target, minimum,
                                 (identity[0], identity[1], expected[identity]))
    need(seen == set(expected), "FriBidi compile-command native/shipping closure is incomplete")


def subtitle_pc(body, library, prefix):
    text = subtitle_text(body, "pkg-config metadata")
    variables, fields = {}, {}
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if "=" in line and (":" not in line or line.index("=") < line.index(":")):
            name, item = line.split("=", 1)
            target = variables
        elif ":" in line:
            name, item = line.split(":", 1)
            target = fields
        else:
            need(False, "Subtitle pkg-config metadata has an unclassified line")
        name, item = name.strip(), item.strip()
        need(name and name not in target and "\x00" not in item,
             "Subtitle pkg-config metadata has a duplicate field")
        target[name] = item
    need(variables.get("prefix") == str(prefix) and
         fields.get("Version") == ("26.7.20" if library == "libfreetype" else SUBTITLE_VERSIONS[library]),
         "Subtitle pkg-config prefix/version differs from fixed build")
    if library == 'libfreetype':
        need(fields.get('Requires') == 'zlib' and not fields.get('Requires.private', '') and fields.get('Libs') == '-L${libdir} -lfreetype' and fields.get('Cflags') == '-I${includedir}/freetype2', 'FreeType exact SDKzlib PC closure')
    elif library == 'libbluray':
        # Meson exposes static-library dependencies publicly; require that exact closure.
        need(re.fullmatch(r'freetype2,[ \t]+libxml-2\.0[ \t]+>=[ \t]+2\.6', fields.get('Requires', '')) is not None
             and 'Requires.private' not in fields
             and not any(item in text for item in ('-ludfread', '/opt/homebrew', '/usr/local/', 'fontconfig')),
             'Libbluray pkg-config dependency closure differs')
    else:
        need(not fields.get("Requires", "") and not fields.get("Requires.private", ""),
             "Subtitle pkg-config unexpectedly admits another package dependency")
    expected_lib = {"libunibreak": "-lunibreak", "libfribidi": "-lfribidi",
                    "libharfbuzz": "-lharfbuzz", 'libbluray': '-lbluray', 'libfreetype': '-lfreetype'}[library]
    need(expected_lib in fields.get("Libs", "").split(),
         "Subtitle pkg-config library identity differs")


def subtitle_header(body, library):
    text = subtitle_text(body, "installed version header")
    if library == 'libfreetype':
        for name, value in (('FREETYPE_MAJOR','2'),('FREETYPE_MINOR','15'),('FREETYPE_PATCH','0')):
            _bluray_define(text, name, value)
    elif library == 'libbluray':
        for name, value in (('BLURAY_VERSION_MAJOR', '1'), ('BLURAY_VERSION_MINOR', '5'), ('BLURAY_VERSION_MICRO', '0')):
            _bluray_define(text, name, value)
        _bluray_define(text, 'BLURAY_VERSION_STRING', '1.5.0', True)
    elif library == "libunibreak":
        definitions = re.findall(r"^[ \t]*#[ \t]*define[ \t]+UNIBREAK_VERSION\b[^\r\n]*$",
                                 text, re.M)
        versions = re.findall(
            r"^[ \t]*#[ \t]*define[ \t]+UNIBREAK_VERSION[ \t]+"
            r"(0[xX][0-9a-fA-F]+)[ \t]*"
            r"(?:/\*(?:[^*\r\n]|\*(?!/)){0,4096}\*/[ \t]*)?$", text, re.M)
        symbols = re.findall(r"^\s*extern\s+const\s+int\s+unibreak_version\s*;\s*$",
                             text, re.M)
        need(len(definitions) == 1 and versions == ["0x0800"] and len(symbols) == 1,
             "Unibreak installed header version")
    elif library == "libfribidi":
        expected = {"FRIBIDI_MAJOR_VERSION": "1", "FRIBIDI_MINOR_VERSION": "0",
                    "FRIBIDI_MICRO_VERSION": "17"}
        for name, version in expected.items():
            definitions = re.findall(r"^[ \t]*#[ \t]*define[ \t]+" +
                                     re.escape(name) + r"\b[^\r\n]*$", text, re.M)
            values = re.findall(r"^[ \t]*#[ \t]*define[ \t]+" + re.escape(name) +
                                r"[ \t]+([0-9]+)[ \t]*$",
                                text, re.M)
            need(len(definitions) == 1 and values == [version],
                 "FriBidi installed header version: " + name)
        definitions = re.findall(
            r"^[ \t]*#[ \t]*define[ \t]+FRIBIDI_VERSION\b[^\r\n]*$", text, re.M)
        strings = re.findall(
            r'^[ \t]*#[ \t]*define[ \t]+FRIBIDI_VERSION[ \t]+"([^"]+)"[ \t]*$',
                             text, re.M)
        need(len(definitions) == 1 and strings == ["1.0.17"],
             "FriBidi installed header string version")
    elif library == "libharfbuzz":
        expected = {"HB_VERSION_MAJOR": "15", "HB_VERSION_MINOR": "0",
                    "HB_VERSION_MICRO": "0"}
        for name, version in expected.items():
            definitions = re.findall(r"^[ \t]*#[ \t]*define[ \t]+" +
                                     re.escape(name) + r"\b[^\r\n]*$", text, re.M)
            values = re.findall(r"^[ \t]*#[ \t]*define[ \t]+" + re.escape(name) +
                                r"[ \t]+([0-9]+)[ \t]*$",
                                text, re.M)
            need(len(definitions) == 1 and values == [version],
                 "HarfBuzz installed header version: " + name)
        definitions = re.findall(
            r"^[ \t]*#[ \t]*define[ \t]+HB_VERSION_STRING\b[^\r\n]*$", text, re.M)
        strings = re.findall(
            r'^[ \t]*#[ \t]*define[ \t]+HB_VERSION_STRING[ \t]+"([^"]+)"[ \t]*$',
                             text, re.M)
        need(len(definitions) == 1 and strings == ["15.0.0"],
             "HarfBuzz installed header string version")


def _bluray_fields(body, label):
    variables, fields = {}, {}
    for raw in subtitle_text(body, label).splitlines():
        line = raw.strip()
        if not line or line.startswith('#'):
            continue
        if '=' in line and (':' not in line or line.index('=') < line.index(':')):
            name, value = line.split('=', 1)
            target = variables
        elif ':' in line:
            name, value = line.split(':', 1)
            target = fields
        else:
            raise ValueError('libbluray dependency metadata has an unknown line')
        name, value = name.strip(), value.strip()
        if not name or name in target:
            raise ValueError('libbluray dependency metadata has duplicate fields')
        target[name] = value
    return variables, fields


def _bluray_define(text, name, expected, quoted=False):
    lines = re.findall(r'^[ \t]*#[ \t]*define[ \t]+' + re.escape(name) + r'\b[^\r\n]*$', text, re.M)
    undefs = re.findall(r'^[ \t]*#[ \t]*undef[ \t]+' + re.escape(name) + r'\b[^\r\n]*$', text, re.M)
    value = ('"' + re.escape(expected) + '"') if quoted else re.escape(expected)
    if undefs or len(lines) != 1 or re.fullmatch(r'[ \t]*#[ \t]*define[ \t]+' + re.escape(name) + r'[ \t]+' + value + r'[ \t]*', lines[0]) is None:
        raise ValueError('libbluray configured macro differs: ' + name)


def _bluray_config(generated):
    config = subtitle_text(generated['config.h'], 'libbluray config.h')
    _bluray_define(config, 'VERSION', '1.5.0', True)
    for name in ('HAVE_FT2', 'HAVE_LIBXML2', 'HAVE_LIBUDFREAD'):
        _bluray_define(config, name, '1')
    if re.search(r'^[ \t]*#[ \t]*define[ \t]+HAVE_FONTCONFIG\b', config, re.M):
        raise ValueError('libbluray configured fontconfig despite disabled policy')
    _bluray_define(subtitle_text(generated['contrib/libudfread/config.h'], 'embedded UDF config'), 'HAVE_UDFREAD_VERSION_H', '1')


def _bluray_dependencies(body, work, platform, arch, sdk_root):
    value = crypto_load(body)
    if type(value) is not list or len(value) > 10000:
        raise ValueError('libbluray dependency set is unbounded')
    rows, frameworks = {}, set()
    allowed = {'freetype2', 'libxml-2.0', 'libudfread', 'threads', 'appleframeworks'}
    ft = str(work / 'dist/libfreetype' / platform / 'thin' / arch)
    for row in value:
        if (type(row) is not dict or not isinstance(row.get('name'), str) or row['name'] not in allowed
                or (row['name'] in rows and row['name'] != 'appleframeworks')):
            raise ValueError('libbluray dependency name is unknown or duplicate')
        name = row['name']
        rows[name] = row
        for key in ('compile_args', 'link_args'):
            if type(row.get(key)) is not list or any(not isinstance(item, str) or len(item) > 65536 or '\x00' in item for item in row[key]):
                raise ValueError('libbluray dependency arguments are malformed')
        all_args = row['compile_args'] + row['link_args']
        if any('/opt/homebrew' in item or '/usr/local/' in item or 'wrapdb' in item.casefold() for item in all_args):
            raise ValueError('libbluray admits a host/fetch dependency')
        if name == 'freetype2':
            if ('-I' + ft + '/include/freetype2' not in row['compile_args']
                    or not ({'-lfreetype', ft + '/lib/libfreetype.a'} & set(row['link_args']))
                    or row['compile_args'] != ['-I' + ft + '/include/freetype2']
                    or set(row['link_args']) - {'-L' + ft + '/lib', '-lfreetype', ft + '/lib/libfreetype.a',
                                                '-lz', sdk_root + '/usr/lib/libz.tbd', sdk_root + '/usr/lib/libz.1.tbd'}):
                raise ValueError('libbluray Freetype dependency is not the retained target provider')
        elif name == 'libxml-2.0':
            if ('-I' + sdk_root + '/usr/include/libxml2' not in row['compile_args']
                    or row['compile_args'] != ['-I' + sdk_root + '/usr/include/libxml2']
                    or not row['link_args']
                    or set(row['link_args']) - {'-lxml2', sdk_root + '/usr/lib/libxml2.tbd', sdk_root + '/usr/lib/libxml2.2.tbd'}):
                raise ValueError('libbluray XML dependency is not the selected SDK provider')
        elif name == 'libudfread':
            if (row.get('type') != 'internal' or row.get('version') != '1.2.0'
                    or any(item.startswith('-L') or item == '-ludfread' for item in row['link_args'])):
                raise ValueError('libbluray admits external/wrong-version UDF')
        elif name == 'threads':
            if any(item != '-pthread' for item in all_args):
                raise ValueError('libbluray thread dependency admits foreign flags')
        elif name == 'appleframeworks':
            args = row['link_args']
            admitted = {'CoreFoundation', 'DiskArbitration'} if platform == 'macos' else {'CoreFoundation'}
            if (row['compile_args'] or not args or len(args) % 2
                    or any(args[index] != '-framework' or args[index + 1] not in admitted
                           for index in range(0, len(args), 2))):
                raise ValueError('libbluray Apple framework selection differs')
            selected = set(args[1::2])
            if len(selected) != len(args) // 2 or selected & frameworks:
                raise ValueError('libbluray Apple framework dependency is duplicated')
            frameworks.update(selected)
    if not {'freetype2', 'libxml-2.0'} <= set(rows):
        raise ValueError('libbluray enabled dependencies are missing')


def _bluray_dependency_paths(work, platform, arch, sdk_root):
    ft = 'dist/libfreetype/' + platform + '/thin/' + arch
    metadata = 'dist/libbluray/' + platform + '/scratch/' + arch + '/vortx-sdk-pkgconfig/'
    return {
        'freetypeArchive': ft + '/lib/libfreetype.a',
        'freetypePC': ft + '/lib/pkgconfig/freetype2.pc',
        'freetypeHeader': ft + '/include/freetype2/freetype/freetype.h',
        'sdkLibxmlPC': metadata + 'libxml-2.0.pc',
        'sdkLibxmlHeader': sdk_root + '/usr/include/libxml2/libxml/xmlversion.h',
        'sdkLibxmlStub': sdk_root + '/usr/lib/libxml2.tbd',
        'sdkZlibPC': metadata + 'zlib.pc',
        'sdkZlibHeader': sdk_root + '/usr/include/zlib.h',
        'sdkZlibStub': sdk_root + '/usr/lib/libz.tbd',
    }


def _bluray_dependency_inputs(value, work, platform, arch, sdk_root, budget):
    expected = _bluray_dependency_paths(work, platform, arch, sdk_root)
    if type(value) is not dict or set(value) != set(expected):
        raise ValueError('libbluray dependency input family differs')
    decoded, before = {}, budget[0]
    for name, relative in expected.items():
        row = value[name]
        fields = {'path', 'bytes', 'sha256'} | (set() if name == 'freetypeArchive' else {'bodyBase64'})
        if (type(row) is not dict or set(row) != fields or row['path'] != relative
                or type(row['bytes']) is not int or not 0 < row['bytes'] <= (512 * 1024 * 1024 if name == 'freetypeArchive' else 4 * 1024 * 1024)
                or not isinstance(row['sha256'], str) or re.fullmatch(r'[0-9a-f]{64}', row['sha256']) is None):
            raise ValueError('libbluray dependency input row differs: ' + name)
        if name != 'freetypeArchive':
            decoded[name] = subtitle_inline({key: row[key] for key in ('bytes', 'sha256', 'bodyBase64')}, 'bluray dependency ' + name, budget, 4 * 1024 * 1024)
    if budget[0] - before > 8 * 1024 * 1024:
        raise ValueError('libbluray dependency raw-body family exceeds cap')
    ft = str(work / 'dist/libfreetype' / platform / 'thin' / arch)
    variables, fields = _bluray_fields(decoded['freetypePC'], 'retained Freetype pc')
    if (variables != {'prefix': ft, 'includedir': '${prefix}/include', 'libdir': '${prefix}/lib'}
            or fields.get('Requires') != 'zlib' or fields.get('Requires.private', '')
            or fields.get('Libs') != '-L${libdir} -lfreetype'
            or fields.get('Cflags') != '-I${includedir}/freetype2'
            or re.fullmatch(r'[0-9]{1,3}(?:\.[0-9]{1,3}){1,3}', fields.get('Version', '')) is None):
        raise ValueError('libbluray retained Freetype pkg-config identity differs')
    ft_header = subtitle_text(decoded['freetypeHeader'], 'retained Freetype header')
    for macro in ('FREETYPE_MAJOR', 'FREETYPE_MINOR', 'FREETYPE_PATCH'):
        if len(re.findall(r'^[ \t]*#[ \t]*define[ \t]+' + macro + r'[ \t]+[0-9]{1,3}[ \t]*$', ft_header, re.M)) != 1:
            raise ValueError('libbluray retained Freetype header lacks bounded version macros')
    for kind, macro, include, install_name in (
            ('Libxml', 'LIBXML_DOTTED_VERSION', 'usr/include/libxml2', '/usr/lib/libxml2.2.dylib'),
            ('Zlib', 'ZLIB_VERSION', '', '/usr/lib/libz.1.dylib')):
        header = subtitle_text(decoded['sdk' + kind + 'Header'], 'SDK version header')
        definitions = re.findall(r'^[ \t]*#[ \t]*define[ \t]+' + macro + r'\b[^\r\n]*$', header, re.M)
        versions = re.findall(r'^[ \t]*#[ \t]*define[ \t]+' + macro + r'[ \t]+"([0-9]{1,3}(?:\.[0-9]{1,3}){1,3})"[ \t]*$', header, re.M)
        if len(definitions) != 1 or len(versions) != 1:
            raise ValueError('libbluray selected SDK version header differs')
        if kind == 'Libxml':
            include_path = (sdk_root + '/' + include).replace('\\', '\\\\').replace('"', '\\"')
            expected_pc = 'Name: libxml-2.0\nDescription: Target Apple SDK libxml2\nVersion: ' + versions[0] + '\nLibs: -lxml2\nCflags: -I"' + include_path + '"\n'
        else:
            expected_pc = 'Name: zlib\nDescription: Target Apple SDK zlib\nVersion: ' + versions[0] + '\nLibs: -lz\nCflags:\n'
        if decoded['sdk' + kind + 'PC'] != expected_pc.encode():
            raise ValueError('libbluray selected SDK pkg-config bytes differ')
        stub = subtitle_text(decoded['sdk' + kind + 'Stub'], 'SDK linker stub')
        escaped = re.escape(install_name)
        if not stub.startswith('--- !tapi-tbd') or len(re.findall(r'(?m)^install-name:[ \t]+(?:' + escaped + r"|'"+ escaped + r"'|\"" + escaped + r'\")[ \t]*$', stub)) != 1:
            raise ValueError('libbluray selected SDK linker identity differs')
    return decoded




FREETYPE_OPTION_TOKENS = '#ifndef FTOPTION_H_ #define FTOPTION_H_ #include <ft2build.h> FT_BEGIN_HEADER #define FT_CONFIG_OPTION_ENVIRONMENT_PROPERTIES #undef FT_CONFIG_OPTION_FORCE_INT64 #define FT_CONFIG_OPTION_INLINE_MULFIX #define FT_CONFIG_OPTION_USE_LZW #define FT_CONFIG_OPTION_USE_ZLIB #define FT_CONFIG_OPTION_SYSTEM_ZLIB #define FT_CONFIG_OPTION_POSTSCRIPT_NAMES #define FT_CONFIG_OPTION_ADOBE_GLYPH_LIST #define FT_CONFIG_OPTION_MAC_FONTS #ifdef FT_CONFIG_OPTION_MAC_FONTS #define FT_CONFIG_OPTION_GUESSING_EMBEDDED_RFORK #endif #define FT_CONFIG_OPTION_INCREMENTAL #define FT_RENDER_POOL_SIZE 16384L #define FT_MAX_MODULES 32 #undef FT_CONFIG_OPTION_USE_MODULE_ERRORS #define FT_CONFIG_OPTION_SVG #define TT_CONFIG_OPTION_EMBEDDED_BITMAPS #define TT_CONFIG_OPTION_COLOR_LAYERS #define TT_CONFIG_OPTION_POSTSCRIPT_NAMES #define TT_CONFIG_OPTION_SFNT_NAMES #define TT_CONFIG_CMAP_FORMAT_0 #define TT_CONFIG_CMAP_FORMAT_2 #define TT_CONFIG_CMAP_FORMAT_4 #define TT_CONFIG_CMAP_FORMAT_6 #define TT_CONFIG_CMAP_FORMAT_8 #define TT_CONFIG_CMAP_FORMAT_10 #define TT_CONFIG_CMAP_FORMAT_12 #define TT_CONFIG_CMAP_FORMAT_13 #define TT_CONFIG_CMAP_FORMAT_14 #define TT_CONFIG_CMAP_FORMAT_15 #define TT_CONFIG_OPTION_BYTECODE_INTERPRETER #define TT_CONFIG_OPTION_SUBPIXEL_HINTING #undef TT_CONFIG_OPTION_COMPONENT_OFFSET_SCALED #define TT_CONFIG_OPTION_GX_VAR_SUPPORT #define TT_CONFIG_OPTION_VARC #define TT_CONFIG_OPTION_BDF #ifndef TT_CONFIG_OPTION_MAX_RUNNABLE_OPCODES #define TT_CONFIG_OPTION_MAX_RUNNABLE_OPCODES 1000000L #endif #define T1_MAX_DICT_DEPTH 5 #define T1_MAX_SUBRS_CALLS 16 #define T1_MAX_CHARSTRINGS_OPERANDS 256 #undef T1_CONFIG_OPTION_NO_AFM #undef T1_CONFIG_OPTION_NO_MM_SUPPORT #define CFF_CONFIG_OPTION_DARKENING_PARAMETER_X1 500 #define CFF_CONFIG_OPTION_DARKENING_PARAMETER_Y1 400 #define CFF_CONFIG_OPTION_DARKENING_PARAMETER_X2 1000 #define CFF_CONFIG_OPTION_DARKENING_PARAMETER_Y2 275 #define CFF_CONFIG_OPTION_DARKENING_PARAMETER_X3 1667 #define CFF_CONFIG_OPTION_DARKENING_PARAMETER_Y3 275 #define CFF_CONFIG_OPTION_DARKENING_PARAMETER_X4 2333 #define CFF_CONFIG_OPTION_DARKENING_PARAMETER_Y4 0 #define AF_CONFIG_OPTION_CJK #ifdef AF_CONFIG_OPTION_CJK #define AF_CONFIG_OPTION_INDIC #endif #ifdef TT_CONFIG_OPTION_BYTECODE_INTERPRETER #define TT_USE_BYTECODE_INTERPRETER #ifdef TT_CONFIG_OPTION_SUBPIXEL_HINTING #define TT_SUPPORT_SUBPIXEL_HINTING_MINIMAL #endif #endif #ifdef TT_CONFIG_OPTION_COLOR_LAYERS #define TT_SUPPORT_COLRV1 #endif #if CFF_CONFIG_OPTION_DARKENING_PARAMETER_X1 < 0 || \\ CFF_CONFIG_OPTION_DARKENING_PARAMETER_X2 < 0 || \\ CFF_CONFIG_OPTION_DARKENING_PARAMETER_X3 < 0 || \\ CFF_CONFIG_OPTION_DARKENING_PARAMETER_X4 < 0 || \\ \\ CFF_CONFIG_OPTION_DARKENING_PARAMETER_Y1 < 0 || \\ CFF_CONFIG_OPTION_DARKENING_PARAMETER_Y2 < 0 || \\ CFF_CONFIG_OPTION_DARKENING_PARAMETER_Y3 < 0 || \\ CFF_CONFIG_OPTION_DARKENING_PARAMETER_Y4 < 0 || \\ \\ CFF_CONFIG_OPTION_DARKENING_PARAMETER_X1 > \\ CFF_CONFIG_OPTION_DARKENING_PARAMETER_X2 || \\ CFF_CONFIG_OPTION_DARKENING_PARAMETER_X2 > \\ CFF_CONFIG_OPTION_DARKENING_PARAMETER_X3 || \\ CFF_CONFIG_OPTION_DARKENING_PARAMETER_X3 > \\ CFF_CONFIG_OPTION_DARKENING_PARAMETER_X4 || \\ \\ CFF_CONFIG_OPTION_DARKENING_PARAMETER_Y1 > 500 || \\ CFF_CONFIG_OPTION_DARKENING_PARAMETER_Y2 > 500 || \\ CFF_CONFIG_OPTION_DARKENING_PARAMETER_Y3 > 500 || \\ CFF_CONFIG_OPTION_DARKENING_PARAMETER_Y4 > 500 #error "Invalid CFF darkening parameters!" #endif FT_END_HEADER #endif'
FREETYPE_MODULE_HEADER = b'/* This is a generated file. */\nFT_USE_MODULE( FT_Driver_ClassRec, tt_driver_class )\nFT_USE_MODULE( FT_Driver_ClassRec, t1_driver_class )\nFT_USE_MODULE( FT_Driver_ClassRec, cff_driver_class )\nFT_USE_MODULE( FT_Driver_ClassRec, t1cid_driver_class )\nFT_USE_MODULE( FT_Driver_ClassRec, hvf_driver_class )\nFT_USE_MODULE( FT_Driver_ClassRec, pfr_driver_class )\nFT_USE_MODULE( FT_Driver_ClassRec, t42_driver_class )\nFT_USE_MODULE( FT_Driver_ClassRec, winfnt_driver_class )\nFT_USE_MODULE( FT_Driver_ClassRec, pcf_driver_class )\nFT_USE_MODULE( FT_Driver_ClassRec, bdf_driver_class )\nFT_USE_MODULE( FT_Module_Class, sfnt_module_class )\nFT_USE_MODULE( FT_Module_Class, autofit_module_class )\nFT_USE_MODULE( FT_Module_Class, pshinter_module_class )\nFT_USE_MODULE( FT_Renderer_Class, ft_smooth_renderer_class )\nFT_USE_MODULE( FT_Renderer_Class, ft_raster1_renderer_class )\nFT_USE_MODULE( FT_Renderer_Class, ft_svg_renderer_class )\nFT_USE_MODULE( FT_Renderer_Class, ft_sdf_renderer_class )\nFT_USE_MODULE( FT_Renderer_Class, ft_bitmap_sdf_renderer_class )\nFT_USE_MODULE( FT_Module_Class, psaux_module_class )\nFT_USE_MODULE( FT_Module_Class, psnames_module_class )\n/* EOF */\n'

def freetype_configuration(generated, installed, commands, work, platform, arch, sdk_root):
    option = installed['include/freetype2/freetype/config/ftoption.h']
    modules = installed['include/freetype2/freetype/config/ftmodule.h']
    if option != generated['ftoption.h'] or modules != generated['ftmodule.h'] or modules != FREETYPE_MODULE_HEADER:
        raise ValueError('FreeType generated/installed option/module correspondence differs')
    functional = ' '.join(re.sub(r'/\*.*?\*/', '', subtitle_text(option, 'FreeType options'), flags=re.S).split())
    if functional != FREETYPE_OPTION_TOKENS:
        raise ValueError('FreeType source-default feature contract differs; systemzlib only enabled integration')
    config = installed['include/freetype2/freetype/config/ftconfig.h']
    if hashlib.sha1(b'blob ' + str(len(config)).encode() + b'\0' + config).hexdigest() != FREETYPE_GIT_FILES['include/freetype/config/ftconfig.h'][1]:
        raise ValueError('FreeType mmapdisabled config header differs from source')
    build = work / 'dist/libfreetype' / platform / 'scratch' / arch
    source = work / 'dist/libfreetype-2.15.0-37515cf5'
    pc = subtitle_text(generated['vortx-sdk-pkgconfig/zlib.pc'], 'FreeType SDKzlib pc')
    if re.fullmatch(r'Name: zlib\nDescription: Target Apple SDK zlib\nVersion: [0-9]{1,3}(?:\.[0-9]{1,3}){1,3}\nLibs: -lz\nCflags:\n', pc) is None:
        raise ValueError('FreeType generated SDKzlib metadata differs')
    dependencies = crypto_load(generated['meson-info/intro-dependencies.json'])
    if type(dependencies) is not list or len(dependencies) != 1:
        raise ValueError('FreeType dependency family is not exactly SDKzlib')
    dep = dependencies[0]
    version = re.search(r'(?m)^Version: (.+)$',pc).group(1)
    if type(dep) is not dict or dep.get('name') != 'zlib' or dep.get('version') != version or dep.get('compile_args') != [] or dep.get('link_args') != ['-lz']:
        raise ValueError('FreeType SDKzlib effective dependency differs')
    for row in commands:
        if row.get('directory') != str(build) or not isinstance(row.get('file'),str) or not isinstance(row.get('output'),str):
            raise ValueError('FreeType compile source/output identity differs')
        resolved = Path(os.path.normpath(os.path.join(str(build),row['file'])))
        if not resolved.is_relative_to(source) or resolved.relative_to(source).as_posix() not in FREETYPE_GIT_FILES or not str(resolved).endswith('.c'):
            raise ValueError('FreeType compilation source escapes exact Git body membership')
        output = Path(os.path.normpath(os.path.join(str(build),row['output'])))
        if not output.is_relative_to(build) or output == build:
            raise ValueError('FreeType compile output escapes scratch')
        payloads = ([row['arguments']] if 'arguments' in row else []) + ([shlex.split(row['command'])] if 'command' in row else [])
        for args in payloads:
            def argument_values(flag):
                indexes = [i for i,x in enumerate(args) if x == flag]
                if any(i+1 >= len(args) for i in indexes):
                    raise ValueError('FreeType unterminated compile selector')
                return [args[i+1] for i in indexes]
            if (argument_values('-c') != [row['file']] or argument_values('-o') != [row['output']]
                    or [x for x in args if not x.startswith('-') and x.endswith('.c')] != [row['file']]
                    or any(x in ('-D','-U','--') or (x.startswith('-o') and x != '-o') or x.startswith(('--output','-iquote','-idirafter','-iframework','-F')) for x in args)):
                raise ValueError('FreeType command/source/output or alternate provider selector differs')
            if args[0] != '/usr/bin/clang' or [x for x in args if x.startswith('-O')] != ['-O3'] or any(x in ('-include','-imacros','-Xpreprocessor','-Xclang') or x.startswith(('@','-Wp,','-include','-imacros','-isystem')) for x in args):
                raise ValueError('FreeType compiler/optimization/forced-header route differs')
            critical = [x for x in args if re.match(r'^-[DU](?:FT2_|FT_|TT_|T1_|CFF_)',x)]
            if sorted(critical) != sorted(['-DFT2_BUILD_LIBRARY=1','-DFT_CONFIG_MODULES_H=<ftmodule.h>','-DFT_CONFIG_OPTIONS_H=<ftoption.h>']):
                raise ValueError('FreeType compile feature/header macro route differs')
            for index, arg in enumerate(args):
                if arg == '-I':
                    if index + 1 >= len(args): raise ValueError('FreeType unterminated include')
                    include = args[index+1]
                elif arg.startswith('-I'): include = arg[2:]
                else: continue
                location = Path(os.path.normpath(os.path.join(str(build),include)))
                if not (location.is_relative_to(build) or location.is_relative_to(source) or location.is_relative_to(Path(sdk_root))):
                    raise ValueError('FreeType compiler admits a host/provider include root')


def freetype_dependency_paths(work, platform, arch, sdk_root):
    return {'freetypeArchive': 'dist/libfreetype/' + platform + '/thin/' + arch + '/lib/libfreetype.a',
            'sdkZlibHeader': sdk_root + '/usr/include/zlib.h',
            'sdkZlibStub': sdk_root + '/usr/lib/libz.tbd',
            'sdkSettings': sdk_root + '/SDKSettings.json'}


def freetype_dependency_inputs(value, record, work, platform, arch, sdk_root, budget):
    paths = freetype_dependency_paths(work, platform, arch, sdk_root)
    if type(value) is not dict or set(value) != set(paths):
        raise ValueError('FreeType archive/SDK input family differs')
    decoded = {}
    for name, path in paths.items():
        row = value[name]
        wanted = {'path','bytes','sha256'} | (set() if name == 'freetypeArchive' else {'bodyBase64'})
        if type(row) is not dict or set(row) != wanted or row['path'] != path or type(row['bytes']) is not int or not 0 < row['bytes'] <= (512*1024*1024 if name == 'freetypeArchive' else 4*1024*1024) or not isinstance(row['sha256'],str) or re.fullmatch(r'[0-9a-f]{64}',row['sha256']) is None:
            raise ValueError('FreeType archive/SDK input wrapper differs')
        if name != 'freetypeArchive':
            decoded[name] = subtitle_inline({x:row[x] for x in ('bytes','sha256','bodyBase64')}, 'FreeType '+name, budget, 4*1024*1024)
    header = subtitle_text(decoded['sdkZlibHeader'],'SDKzlib header')
    versions = re.findall(r'(?m)^\s*#\s*define\s+ZLIB_VERSION\s+"([0-9]{1,3}(?:\.[0-9]{1,3}){1,3})"\s*$',header)
    if len(versions) != 1:
        raise ValueError('FreeType SDKzlib version header differs')
    pc_row = record['generatedConfiguration']['vortx-sdk-pkgconfig/zlib.pc']
    pc = subtitle_inline(pc_row,'FreeType SDKzlib metadata',budget)
    expected = ('Name: zlib\nDescription: Target Apple SDK zlib\nVersion: '+versions[0]+'\nLibs: -lz\nCflags:\n').encode()
    if pc != expected:
        raise ValueError('FreeType generated SDKzlib metadata/header correspondence differs')
    stub = subtitle_text(decoded['sdkZlibStub'],'SDKzlib stub')
    install_pattern = r"""(?m)^install-name:[ \t]+(?:/usr/lib/libz\.1\.dylib|'/usr/lib/libz\.1\.dylib'|"/usr/lib/libz\.1\.dylib")[ \t]*$"""
    if (not stub.startswith('--- !tapi-tbd') or len(re.findall(r'(?m)^install-name:[^\r\n]*$',stub)) != 1
            or len(re.findall(install_pattern,stub)) != 1):
        raise ValueError('FreeType selected SDKzlib linker identity differs')
    settings = crypto_load(decoded['sdkSettings'])
    if type(settings) is not dict or not isinstance(settings.get('Version'),str) or re.fullmatch(r'[0-9]{1,3}(?:\.[0-9]{1,3}){0,3}',settings['Version']) is None:
        raise ValueError('FreeType selected SDKSettings identity differs')
    return decoded

def subtitle_record_contract(record, work, library, platform, arch, budget):
    expected_keys = {"schema", "library", "selector", "route", "platform", "arch",
                     "sourceDirectory", "buildDirectory", "prefix", "arguments",
                     "environment", "makeArguments", "generatedConfiguration",
                     "installedIdentity", "compiled", "installed"}
    need(type(record) is dict and set(record) == expected_keys,
         "Subtitle build record keys differ from Swift producer")
    source = work / "dist" / (library + "-" + SUBTITLE_SELECTORS[library])
    build = work / "dist" / library / platform / "scratch" / arch
    prefix = work / "dist" / library / platform / "thin" / arch
    _, _, _, host, _, _, _ = subtitle_platform(platform, arch)
    arguments = (("--host=" + host, "--with-pic", "--enable-static", "--disable-shared")
                 if library == "libunibreak" else SUBTITLE_ARGUMENTS[library])
    fixed = {"schema": 1, "library": library,
             "selector": SUBTITLE_SELECTORS[library],
             "route": SUBTITLE_ROUTES[library], "platform": platform, "arch": arch,
             "sourceDirectory": str(source), "buildDirectory": str(build),
             "prefix": str(prefix), "arguments": list(arguments),
             "makeArguments": (list(SUBTITLE_MAKE_ARGUMENTS)
                               if library == "libunibreak" else []),
             "compiled": True, "installed": True}
    need(all(exact_equal(record[name], item) for name, item in fixed.items()),
         "Subtitle build record identity/options differ from fixed policy")
    sdk_root, cflags, ldflags = subtitle_environment(
        record["environment"], work, library, platform, arch)
    generated_names = set(SUBTITLE_GENERATED[library])
    if library == "libunibreak" and "config.h" in record["generatedConfiguration"]:
        generated_names.add("config.h")
    need(type(record["generatedConfiguration"]) is dict and
         set(record["generatedConfiguration"]) == generated_names and
         type(record["installedIdentity"]) is dict and
         set(record["installedIdentity"]) == set(SUBTITLE_INSTALLED[library]),
         "Subtitle generated/installed file set differs")
    before = budget[0]
    generated = {name: subtitle_inline(record["generatedConfiguration"][name],
                                        library + "/" + name, budget)
                 for name in sorted(generated_names)}
    installed = {name: subtitle_inline(record["installedIdentity"][name],
                                        library + "/" + name, budget)
                 for name in SUBTITLE_INSTALLED[library]}
    need(budget[0] - before <= SUBTITLE_MAX_RECORD_BODIES,
         "Subtitle per-record nested raw-body cap")
    if library == "libunibreak":
        makefile = subtitle_text(generated["Makefile"], "libunibreak Makefile")
        logs = (subtitle_text(generated["config.status"], "libunibreak config.status") +
                "\n" + subtitle_text(generated["config.log"], "libunibreak config.log"))
        assignments = {"CC": record["environment"]["CC"], "CFLAGS": record["environment"]["CFLAGS"],
                       "CPPFLAGS": cflags, "LDFLAGS": ldflags,
                       "PACKAGE_VERSION": "8.0", "prefix": str(prefix)}
        for name, expected in assignments.items():
            modifier_lines = re.findall(
                r"^[ \t]*(?:(?:override|export|private|unexport)[ \t]+)+" +
                re.escape(name) + r"\b[^\r\n]*$", makefile, re.M)
            assignment_lines = re.findall(
                r"^[ \t]*" + re.escape(name) +
                r"[ \t]*(?:::=|::=|:=|\+=|\?=|!=|=)[^\r\n]*$",
                makefile, re.M)
            values = re.findall(r"^[ \t]*" + re.escape(name) +
                                r"[ \t]*=[ \t]*([^\r\n]*?)[ \t]*$",
                                makefile, re.M)
            need(not modifier_lines and len(assignment_lines) == 1 and
                 values == [expected],
                 "Libunibreak generated Makefile assignment differs: " + name)
        need(all(argument in logs for argument in arguments),
             "Libunibreak generated configuration differs from fixed release options")
        if "config.h" in generated:
            subtitle_text(generated["config.h"], "libunibreak config.h")
    else:
        subtitle_meson_cross(generated["crossFile.meson"], work, library, platform,
                             arch, sdk_root, cflags, ldflags)
        ninja = subtitle_text(generated["build.ninja"], library + " build.ninja")
        need("ninja_required_version" in ninja and
             re.search(r"(?i)(?:^|[\s=])(curl|wget)(?:\s|$)|git\s+clone|wrapdb",
                       ninja) is None,
             "Subtitle Ninja file lacks identity or admits a fetch route")
        commands = crypto_load(generated["compile_commands.json"])
        need(type(commands) is list and 0 < len(commands) <= 100000,
             "Subtitle compile-command set is empty or unbounded")
        _, target, minimum, _, _, _, _ = subtitle_platform(platform, arch)
        if library == "libfribidi":
            subtitle_fribidi_compile_commands(commands, build, arch, sdk_root, target, minimum)
        else:
            for command in commands:
                subtitle_compile_command(command, arch, sdk_root, target, minimum)
        subtitle_build_options(
            generated["meson-info/intro-buildoptions.json"], library, prefix)
        if library == 'libbluray':
            _bluray_config(generated)
            _bluray_dependencies(generated['meson-info/intro-dependencies.json'], work, platform, arch, sdk_root)
            source = str(work / 'dist/libbluray-1.5.0-f676408e') + '/'
            udf = False
            for command in commands:
                need(command.get('directory') == str(build) and isinstance(command.get('file'), str)
                     and isinstance(command.get('output'), str),
                     'Libbluray compile directory/source identity differs')
                name = os.path.normpath(os.path.join(str(build), command['file']))
                need(name.startswith(source) and name.endswith('.c'), 'Libbluray compile source escapes its admitted archive')
                need(os.path.normpath(os.path.join(str(build), command['output'])).startswith(str(build) + '/'),
                     'Libbluray compile output escapes its admitted build')
                subtitle_compile_command(command, arch, sdk_root, target, minimum,
                                         (command['file'], command['output'], False))
                udf |= '/contrib/libudfread/src/' in name
            need(udf, 'Libbluray compile evidence lacks embedded UDF sources')
        elif library == 'libfreetype':
            freetype_configuration(generated, installed, commands, work, platform, arch, sdk_root)
        else:
            subtitle_dependencies(generated["meson-info/intro-dependencies.json"])
    if library == 'libfreetype':
        subtitle_header(installed[SUBTITLE_INSTALLED[library][0]], library)
        subtitle_pc(installed[SUBTITLE_INSTALLED[library][-1]], library, prefix)
        return installed
    header_name, pc_name = SUBTITLE_INSTALLED[library]
    subtitle_header(installed[header_name], library)
    subtitle_pc(installed[pc_name], library, prefix)
    return installed


def subtitle_record_body(row, expected_path, budget):
    keys(row, "path bytes sha256 bodyBase64")
    need(row["path"] == expected_path and path(row["path"]) == expected_path,
         "Subtitle BOM build-record path")
    inline = {name: row[name] for name in ("bytes", "sha256", "bodyBase64")}
    return subtitle_inline(inline, "build record " + expected_path, budget,
                           SUBTITLE_MAX_RECORD)


def freetype_require_composition():
    # Presence is an interface check only; the root-sealed recipe and separate
    # DoviBOM/catalog validators establish real joint content acceptance.
    if globals().get('DOVI_SOURCE_PROFILE') != 'native-upgrades-libdovi340-v1' or globals().get('DOVI_SOURCE_VERSION') != '3.4.0':
        raise ValueError('Unsealed FT/Dovi composition: exact Dovi source policy interface is missing')


def subtitle_builds_receipt(body, zip_bodies, subtitle_archive_sources):
    freetype_require_composition()
    """Independently bind 45 raw subtitle/bluray/FreeType records to source and retained ZIPs."""
    need(isinstance(body, bytes) and 0 < len(body) <= SUBTITLE_MAX_RECEIPT,
         "Subtitle BOM raw-byte bound")
    value = crypto_load(body)
    keys(value, "schemaVersion profile sourceProfile versions selectors "
                "releaseSourceBoundary rows retainedLibassCompatibility "
                "retainedBlurayCompatibility retainedFreetypeAuthentication sourceFreetypeAuthentication runtimeSecurityTested promotionEligible")
    fixed = {"schemaVersion": 1, "profile": NATIVE_UPGRADES_PROFILE,
             "sourceProfile": SUBTITLE_SOURCE_PROFILE,
             "versions": SUBTITLE_VERSIONS, "selectors": SUBTITLE_SELECTORS,
             "retainedLibassCompatibility": "HOLD",
             'retainedBlurayCompatibility': 'HOLD', 'retainedFreetypeAuthentication': 'HOLD',
             'sourceFreetypeAuthentication': 'SOURCE_AND_COMPILER_BOUND',
             "runtimeSecurityTested": False, "promotionEligible": False}
    need(all(exact_equal(value[name], item) for name, item in fixed.items()),
         "Subtitle BOM identity/open-gate state")
    rows = value["rows"]
    need(type(rows) is list and len(rows) == len(SUBTITLE_MATRIX),
         "Subtitle BOM exact nine-row matrix")

    budget, records = [0], {}
    observed = []
    for row, identity in zip(rows, SUBTITLE_MATRIX, strict=True):
        keys(row, "platform arch slice builds")
        platform, arch, slice_name = identity
        need(exact_equal({name: row[name] for name in ("platform", "arch", "slice")},
                         {"platform": platform, "arch": arch, "slice": slice_name}),
             "Subtitle BOM matrix order/identity")
        builds = row["builds"]
        need(type(builds) is dict and set(builds) == set(SUBTITLE_VERSIONS),
             "Subtitle BOM build family")
        for library in SUBTITLE_VERSIONS:
            build = builds[library]
            keys(build, "record dependencyInputs" if library in ('libbluray','libfreetype') else "record")
            expected_path = ("dist/" + library + "/" + platform + "/scratch/" +
                             arch + "/vortx-subtitle-build.json")
            record_body = subtitle_record_body(build["record"], expected_path, budget)
            records[(platform, arch, library)] = crypto_load(record_body)
        observed.append(identity)
    need(observed == list(SUBTITLE_MATRIX), "Subtitle BOM matrix coverage")

    first = records[(SUBTITLE_MATRIX[0][0], SUBTITLE_MATRIX[0][1], "libunibreak")]
    source_name = first.get("sourceDirectory") if type(first) is dict else None
    need(isinstance(source_name, str) and source_name.startswith("/") and
         "\x00" not in source_name and ".." not in Path(source_name).parts,
         "Subtitle BOM absolute WORK identity")
    source = Path(source_name)
    need(source.parent.name == "dist" and
         source.name == "libunibreak-" + SUBTITLE_SELECTORS["libunibreak"],
         "Subtitle BOM source root layout")
    work = source.parent.parent

    keys(subtitle_archive_sources, "profile roots capture")
    need(subtitle_archive_sources["profile"] == SUBTITLE_SOURCE_PROFILE,
         "Subtitle archive-source profile")
    capture = subtitle_archive_sources["capture"]
    keys(capture, "tar receipt")
    source_receipt = capture["receipt"]
    keys(source_receipt, "logicalPath name bytes sha256")
    need(source_receipt["logicalPath"] == "subtitle-release-sources.json" and
         source_receipt["name"] == SUBTITLE_CAPTURE_RECEIPT_OUTPUT and
         type(source_receipt["bytes"]) is int and
         0 < source_receipt["bytes"] <= CRYPTO_MAX_RECEIPT,
         "Subtitle source receipt metadata")
    digest(source_receipt["sha256"])
    expected_boundary = {"path": "dist/subtitle-sources-v4/receipt.json",
                         "bytes": source_receipt["bytes"],
                         "sha256": source_receipt["sha256"]}
    keys(value["releaseSourceBoundary"], "path bytes sha256")
    need(exact_equal(value["releaseSourceBoundary"], expected_boundary),
         "Subtitle BOM/source-helper raw receipt correspondence")

    catalog = crypto_zip_catalog(zip_bodies, SUBTITLE_LIBRARIES)
    library_map = {target: binary_name
                   for target, _, _, binary_name in SUBTITLE_LIBRARIES}
    for platform, arch, slice_name in SUBTITLE_MATRIX:
        for library in SUBTITLE_VERSIONS:
            installed = subtitle_record_contract(
                records[(platform, arch, library)], work, library, platform, arch, budget)
            if library == 'libbluray':
                sdk_root, _, _ = subtitle_environment(records[(platform, arch, library)]['environment'], work, library, platform, arch)
                aggregate = value['rows'][list(SUBTITLE_MATRIX).index((platform, arch, slice_name))]['builds'][library]
                _bluray_dependency_inputs(aggregate['dependencyInputs'], work, platform, arch, sdk_root, budget)
            elif library == 'libfreetype':
                record = records[(platform,arch,library)]
                sdk_root, _, _ = subtitle_environment(record['environment'],work,library,platform,arch)
                aggregate = value['rows'][list(SUBTITLE_MATRIX).index((platform,arch,slice_name))]['builds'][library]
                freetype_dependency_inputs(aggregate['dependencyInputs'],record,work,platform,arch,sdk_root,budget)
                ft_arch = aggregate['dependencyInputs']['freetypeArchive']
                bluray = value['rows'][list(SUBTITLE_MATRIX).index((platform,arch,slice_name))]['builds']['libbluray']['dependencyInputs']
                need(exact_equal(ft_arch,bluray['freetypeArchive']), 'Bluray/newFT exact archive provider')
                for name, header in [('freetypeHeader',SUBTITLE_INSTALLED[library][0]),('freetypePC',SUBTITLE_INSTALLED[library][-1])]:
                    need(exact_equal({x:bluray[name][x] for x in ('bytes','sha256','bodyBase64')},record['installedIdentity'][header]), 'Bluray/newFT header/PC provider')
                binary_path = 'artifacts/Libfreetype.xcframework/' + slice_name + '/Libfreetype.framework/Libfreetype'
                _, binary_member = crypto_zip_row(catalog,'Libfreetype',binary_path)
                binary = crypto_zip_file(catalog,'Libfreetype',binary_member)
                expected_arches = {a for _,a,sl in SUBTITLE_MATRIX if sl == slice_name}
                segments = _macho_arch_hashes(binary)
                if segments is None:
                    need(len(expected_arches) == 1, 'FT thin binary for multiarchitecture slice')
                    segments = {arch:(len(binary),sha(binary))}
                need(set(segments) == expected_arches and segments[arch] == (ft_arch['bytes'],ft_arch['sha256']), 'NewFT framework/thin archive byte correspondence')
                for header in SUBTITLE_INSTALLED[library][1:-1]:
                    catalog_path = 'artifacts/Libfreetype.xcframework/' + slice_name + '/Libfreetype.framework/Headers/' + header.removeprefix('include/')
                    row, member = crypto_zip_row(catalog,'Libfreetype',catalog_path)
                    expected = record['installedIdentity'][header]
                    need((row['bytes'],row['sha256']) == (expected['bytes'],expected['sha256']) and crypto_zip_file(catalog,'Libfreetype',member,SUBTITLE_MAX_BODY) == installed[header], 'FT generated/config header catalog correspondence')

            target = SUBTITLE_TARGETS[library]
            binary_name = library_map[target]
            framework = ("artifacts/" + target + ".xcframework/" + slice_name +
                         "/" + binary_name + ".framework/")
            # BaseBuild keeps Headers shallow on every platform; only the macOS
            # binary/resources are moved under Versions/A and resolved by the
            # existing bounded framework-layout validator below.
            header_path = framework + "Headers/" + SUBTITLE_HEADERS[library]
            zip_row, archive_name = crypto_zip_row(catalog, target, header_path)
            header_name = SUBTITLE_INSTALLED[library][0]
            recorded = records[(platform, arch, library)]["installedIdentity"][header_name]
            need(recorded["bytes"] == zip_row["bytes"] and
                 recorded["sha256"] == zip_row["sha256"] and
                 installed[header_name] ==
                 crypto_zip_file(catalog, target, archive_name, SUBTITLE_MAX_BODY),
                 "Subtitle installed header/raw ZIP correspondence")
            crypto_framework_layout(target, binary_name, slice_name, catalog)
    need(budget[0] <= SUBTITLE_MAX_INLINE_RAW,
         "Subtitle aggregate raw-body cap")
    canonical = (json.dumps(value, indent=2, sort_keys=True) + "\n").encode("utf-8")
    need(body == canonical and len(canonical) <= SUBTITLE_MAX_RECEIPT,
         "Subtitle canonical final BOM bytes")
    return value


DOVI_POLICY_SHA = 'f46c891c881f05c904acaf8b36e3127935905c23e9f66706fede0548c5a7de90'
DOVI_BOOTSTRAP_OPERATOR_SHA = 'fc88799a93fb674a535fc51895b27d9b67c14fda57a05261ce6dcd35218f1906'
# These functions are embedded independently in the producer and consumer.
# Neither maintained reader imports or executes the native producer helper.
DOVI_PROFILE = 'native-upgrades-openssl410-crypto-subtitles-bluray150-freetype2150-libdovi340-v7'
DOVI_SOURCE_PROFILE = 'native-upgrades-libdovi340-v1'
DOVI_SOURCE_VERSION = '3.4.0'
DOVI_SOURCE_COMMIT = 'd1abe0e27ff2c7ab3339614d06db9f8a058af6b2'
DOVI_SOURCE_ROOT = 'libdovi-3.4.0-d1abe0e2'
DOVI_MAP_SHA = '7662a50dee5cf02f35f5da56bed11808fa0e6a7f04c46ddbff05bab8557a30d3'
DOVI_LIBRARY_LOCK_SHA = '5c9f344b8a49f684e409af8304e4e175618098c9b24ed8acafc5f1a469088814'
DOVI_STD_LOCK_SHA = '9e87d1ac04edbf5fa61e27cb21984a83566573a007767713868965fba70acb6d'
DOVI_CARGO_C_SHA = '5ff6e05531e58286d3c02ec0adb7f254e5d532a8d4b667f30b9942d802e1db25'
DOVI_CARGO_C_COMMIT = '22591c05bff0f705ef93530e743f2546236544cf'
DOVI_CARGO_C_LOCK_SHA = 'd3cb865d40625de197b71fa591f1f24c0593b5a24b46b7c126eae7fecf7be315'
DOVI_OUTPUT = 'apple-dovi-builds.json'
DOVI_VENDOR_OUTPUT = 'apple-dovi-vendor-crates.tar'
DOVI_LIMIT = 128 * 1024**2
DOVI_SANDBOX_PROFILE = '(version 1)\n(allow default)\n(deny network*)\n(deny file-write* (subpath (param "SOURCE")) (subpath (param "VENDOR")) (subpath (param "TOOLCHAIN")))\n'
DOVI_LIBRARY_SANDBOX_PROFILE = '(version 1)\n(allow default)\n(deny network*)\n(deny file-write* (subpath (param "SOURCE")))\n(deny file-write* (subpath (param "VENDOR")))\n(deny file-write* (subpath (param "TOOLCHAIN")))\n(deny file-write* (subpath (param "CARGO_C")))\n(deny file-write* (subpath (param "INPUTS")))\n(deny file-write* (subpath (param "WORK_SOURCES")))\n(deny file-write* (subpath (param "CANONICAL_WRAPPER")))\n(deny file-write* (subpath (param "CANONICAL_DOVI")))\n(deny file-write* (subpath (param "REGISTERED_DOVI")))\n(deny file-write* (subpath (param "PROTECTED_00")))\n(deny file-write* (subpath (param "PROTECTED_01")))\n(deny file-write* (subpath (param "PROTECTED_02")))\n(deny file-write* (subpath (param "PROTECTED_03")))\n(deny file-write* (subpath (param "PROTECTED_04")))\n(deny file-write* (subpath (param "PROTECTED_05")))\n(deny file-write* (subpath (param "PROTECTED_06")))\n(deny file-write* (subpath (param "PROTECTED_07")))\n(deny file-write* (subpath (param "PROTECTED_08")))\n(deny file-write* (subpath (param "PROTECTED_09")))\n(deny file-write* (subpath (param "PROTECTED_10")))\n(deny file-write* (subpath (param "SDK_00")))\n(deny file-write* (subpath (param "SDK_01")))\n(deny file-write* (subpath (param "SDK_02")))\n(deny file-write* (subpath (param "SDK_03")))\n(deny file-write* (subpath (param "SDK_04")))\n(deny file-write* (literal (param "WORK")))\n(deny file-write* (literal (param "APPLE_AR")))\n(deny file-write* (literal (param "APPLE_CLANG")))\n(deny file-write* (literal (param "HOST_CLANGXX")))\n(deny file-write* (literal (param "HOST_CMAKE")))\n(deny file-write* (literal (param "HOST_MAKE")))\n(deny file-write* (literal (param "HOST_PERL")))\n(deny file-write* (literal (param "HOST_RANLIB")))\n'

def dovi_library_bindings(work, pins):
    """Portable deterministic readonly provider parameters; no filesystem reads."""
    work = dv_path(str(work), True)
    source = work / "dist" / DOVI_SOURCE_ROOT
    dv_need(pins.get("vendorRoot") == str(work / "dist/dovi-inputs/vendor")
            and pins.get("cargoCRoot") == str(work / "dist/dovi-inputs/cargo-c-install"), "fixed library readonly provider roots")
    rows = [("WORK", work), ("SOURCE", source),
            ("VENDOR", dv_path(pins["vendorRoot"], True)),
            ("TOOLCHAIN", dv_path(pins["toolchainRoot"], True)),
            ("CARGO_C", dv_path(pins["cargoCRoot"], True)),
            ("INPUTS", work / "dist/dovi-inputs"), ("WORK_SOURCES", work / "Sources")]
    if "localSourceProviderReceipt" in pins:
        receipt = pins["localSourceProviderReceipt"]
        dv_need(type(receipt) is dict and receipt.get("scope") == "root-local-dovi-git-provider-v1"
                and work.parent.name == "MPVKit" and work.parent.parent.name == ".worktrees",
                "fixed registered local canonical-source derivation")
        workspace = work.parent.parent.parent
        rows += [("CANONICAL_WRAPPER", workspace / "MPVKit"), ("CANONICAL_DOVI", workspace / "dovi-tool"),
                 ("REGISTERED_DOVI", workspace / ".worktrees/dovi-tool/beta/libdovi-3.4.0-d1abe0e2")]
    else:
        # Hosted genuine-Git mode has no Root-local registered-provider aliases.
        rows += [("CANONICAL_WRAPPER", work / ".git"), ("CANONICAL_DOVI", source), ("REGISTERED_DOVI", source)]
    protected = ("gmp", "gnutls", "libbluray", "libfreetype", "libfribidi", "libharfbuzz", "libunibreak", "nettle", "openssl", "libshaderc", "vulkan")
    rows += [("PROTECTED_" + str(i).zfill(2), work / "dist" / name) for i, name in enumerate(protected)]
    sdks = pins.get("sdks")
    dv_need(type(sdks) is dict and set(sdks) == {"appletvos", "appletvsimulator", "iphoneos", "iphonesimulator", "macosx"}, "all five readonly SDK providers")
    rows += [("SDK_" + str(i).zfill(2), dv_path(sdks[name]["resolvedRoot"], True)) for i, name in enumerate(sorted(sdks))]
    apple, host = pins.get("appleTools"), pins.get("hostNativeTools")
    dv_need(type(apple) is dict and set(apple) == {"ar", "clang"}
            and type(host) is dict and set(host) == {"clangxx", "cmake", "make", "perl", "ranlib"}, "exact readonly Apple/host tools")
    rows += [("APPLE_" + name.upper(), dv_path(apple[name]["path"], True)) for name in sorted(apple)]
    rows += [("HOST_" + name.upper(), dv_path(host[name]["path"], True)) for name in sorted(host)]
    dv_need(len(rows) == 33 and len({key for key, _ in rows}) == 33, "complete deterministic library sandbox parameters")
    return [(key, str(value)) for key, value in rows]


def dovi_library_envelope(work, pins):
    dv_need(pins.get("sandboxExec", {}).get("path") == "/usr/bin/sandbox-exec", "fixed single library sandbox provider")
    envelope = [pins["sandboxExec"]["path"]]
    for name, value in dovi_library_bindings(work, pins):
        envelope += ["-D", name + "=" + value]
    return envelope + ["-p", DOVI_LIBRARY_SANDBOX_PROFILE]


DOVI_MATRIX = (
 ('ios','arm64','aarch64-apple-ios','iphoneos','IPHONEOS_DEPLOYMENT_TARGET','15.0','arm64-apple-ios15.0','ios-arm64',2),
 ('isimulator','arm64','aarch64-apple-ios-sim','iphonesimulator','IPHONEOS_DEPLOYMENT_TARGET','15.0','arm64-apple-ios15.0-simulator','ios-arm64_x86_64-simulator',7),
 ('isimulator','x86_64','x86_64-apple-ios','iphonesimulator','IPHONEOS_DEPLOYMENT_TARGET','15.0','x86_64-apple-ios15.0-simulator','ios-arm64_x86_64-simulator',7),
 ('tvos','arm64','aarch64-apple-tvos','appletvos','TVOS_DEPLOYMENT_TARGET','15.0','arm64-apple-tvos15.0','tvos-arm64_arm64e',3),
 ('tvos','arm64e','arm64e-apple-tvos','appletvos','TVOS_DEPLOYMENT_TARGET','15.0','arm64e-apple-tvos15.0','tvos-arm64_arm64e',3),
 ('tvsimulator','arm64','aarch64-apple-tvos-sim','appletvsimulator','TVOS_DEPLOYMENT_TARGET','15.0','arm64-apple-tvos15.0-simulator','tvos-arm64_x86_64-simulator',8),
 ('tvsimulator','x86_64','x86_64-apple-tvos','appletvsimulator','TVOS_DEPLOYMENT_TARGET','15.0','x86_64-apple-tvos15.0-simulator','tvos-arm64_x86_64-simulator',8),
 ('macos','arm64','aarch64-apple-darwin','macosx','MACOSX_DEPLOYMENT_TARGET','12.0','arm64-apple-macos12.0','macos-arm64_x86_64',1),
 ('macos','x86_64','x86_64-apple-darwin','macosx','MACOSX_DEPLOYMENT_TARGET','12.0','x86_64-apple-macos12.0','macos-arm64_x86_64',1),
)


def dv_require_composition():
    # Presence/selection guard only. The separate five-family/45-record FT
    # reader and nine-row dovi reader must still validate their actual bodies.
    dv_need(SUBTITLE_SOURCE_PROFILE == 'unibreak800-fribidi1017-harfbuzz1500-bluray150-freetype2150-release-sources-v4-pax-ns' and
            len(SUBTITLE_VERSIONS)==5 and SUBTITLE_VERSIONS.get('libfreetype')=='2.15.0',
            'joint FreeType source reader/selection is not composed')


def dv_need(condition, message):
    if not condition:
        raise ValueError('libdovi: ' + message)


def dv_hash(body):
    return hashlib.sha256(body).hexdigest()


def dv_equal(left,right):
    if type(left) is not type(right): return False
    if isinstance(left,dict): return set(left)==set(right) and all(dv_equal(left[key],right[key]) for key in left)
    if isinstance(left,list): return len(left)==len(right) and all(dv_equal(a,b) for a,b in zip(left,right))
    return left==right


def dv_json(body):
    dv_need(isinstance(body, bytes) and 0 < len(body) <= DOVI_LIMIT, 'JSON body bound')
    def unique(pairs):
        result = {}
        for key, value in pairs:
            dv_need(key not in result, 'duplicate JSON key')
            result[key] = value
        return result
    return json.loads(body.decode('utf-8'), object_pairs_hook=unique)


def dv_path(value, absolute=False):
    dv_need(isinstance(value, str) and 0 < len(value) <= 4096 and value.isprintable() and '\\' not in value and
            (not absolute or ('$' not in value and '`' not in value)),
            'bounded path')
    p = Path(value)
    dv_need(p.is_absolute() == absolute and '..' not in p.parts and str(p) == value,
            'canonical path')
    return p


def dv_inline(row, budget, maximum=16 * 1024**2):
    dv_need(type(row) is dict and set(row) == {'path','bytes','sha256','bodyBase64'}, 'inline file shape')
    dv_path(row['path'])
    dv_need(type(row['bytes']) is int and 0 < row['bytes'] <= maximum and
            isinstance(row['sha256'], str) and re.fullmatch('[0-9a-f]{64}',row['sha256']), 'inline identity')
    try:
        body = base64.b64decode(row['bodyBase64'], validate=True)
    except (ValueError, binascii.Error, TypeError) as error:
        raise ValueError('libdovi: invalid base64') from error
    dv_need(len(body) == row['bytes'] and dv_hash(body) == row['sha256'] and
            base64.b64encode(body).decode('ascii') == row['bodyBase64'], 'inline body correspondence')
    budget[0] += len(body)
    dv_need(budget[0] <= DOVI_LIMIT, 'aggregate inline cap')
    return body


def dv_crate_files(body, name, version):
    """Read authenticated source members in memory; never extract or execute."""
    root = name + '-' + version
    result, total, count = {}, 0, 0
    with gzip.GzipFile(fileobj=io.BytesIO(body),mode='rb') as compressed:
        expanded=compressed.read(512*1024**2+1)
    dv_need(len(expanded)<=512*1024**2,'crate expanded stream cap')
    with tarfile.open(fileobj=io.BytesIO(expanded), mode='r:') as package:
        for member in package:
            count+=1
            dv_need(count<=100000, 'crate member count')
            if member.isdir() and member.name.rstrip('/')==root:
                continue
            dv_need(member.name.startswith(root + '/'), 'crate member root')
            rel = member.name[len(root)+1:]
            if not rel and member.isdir():
                continue
            dv_path(rel)
            if member.isdir():
                continue
            dv_need(member.isfile() and not member.issym() and not member.islnk() and
                    0 <= member.size <= 64 * 1024**2 and rel not in result, 'crate member type/size/duplicate')
            with package.extractfile(member) as stream:
                raw = stream.read(member.size + 1)
            dv_need(len(raw) == member.size, 'crate member length')
            total += len(raw)
            dv_need(total <= 512 * 1024**2, 'crate expanded cap')
            result[rel] = raw
    dv_need(result, 'empty source crate')
    return result


def dv_lock(body):
    value = tomllib.loads(body.decode('utf-8'))
    dv_need(type(value.get('package')) is list and 0 < len(value['package']) <= 4096, 'Cargo lock package set')
    result = {}
    for row in value['package']:
        if 'source' not in row:
            continue
        dv_need(row['source'] == 'registry+https://github.com/rust-lang/crates.io-index' and
                re.fullmatch('[0-9a-f]{64}', row.get('checksum','')) and
                re.fullmatch('[A-Za-z0-9_-]+', row.get('name','')) and
                re.fullmatch('[A-Za-z0-9.+_-]+', row.get('version','')), 'unbounded/non-registry lock provider')
        key = (row['name'],row['version'])
        dv_need(key not in result, 'duplicate locked crate')
        result[key] = row['checksum']
    return result


def dv_inputs(rows, budget, work):
    expected = {'inputs','admission','sourceMap','libraryLock','stdLock','cargoCSource','cargoCPackageLock','vendorIndex','hostToolBuild','hostToolOperator','bootstrapInputs','bootstrapAdmission'}
    dv_need(type(rows) is dict and set(rows) == expected, 'source input body set')
    bodies = {key:dv_inline(row,budget,64*1024**2) for key,row in rows.items()}
    logical={'inputs':'inputs.json','admission':'admission.json','sourceMap':'source-map.json','libraryLock':'library-Cargo.lock',
             'stdLock':'std-Cargo.lock','cargoCSource':'cargo-c.crate','cargoCPackageLock':'cargo-c-Cargo.lock',
             'vendorIndex':'vendor-index.json','hostToolBuild':'cargo-c-build.json','hostToolOperator':'cargo-c-host-operator.py',
             'bootstrapInputs':'bootstrap-inputs.json','bootstrapAdmission':'bootstrap-admission.json'}
    dv_need(all(rows[key]['path']=='dovi-inputs/'+name for key,name in logical.items()),'fixed input capture paths')
    pins, admission, mapping = (dv_json(bodies[key]) for key in ('inputs','admission','sourceMap'))
    dv_need(dv_hash(bodies['sourceMap']) == DOVI_MAP_SHA and mapping.get('commit') == DOVI_SOURCE_COMMIT and
            mapping.get('tree') == 'b2183f7cc3d62918ad43b346835a2dab7d2ad875' and len(mapping.get('blobs',[])) == 209,
            'official source map')
    dv_need(dv_hash(bodies['libraryLock']) == DOVI_LIBRARY_LOCK_SHA and dv_hash(bodies['stdLock']) == DOVI_STD_LOCK_SHA,
            'exact nested library/build-std lock')
    dv_need(len(bodies['cargoCSource']) == 66232 and dv_hash(bodies['cargoCSource']) == DOVI_CARGO_C_SHA,
            'official compressed cargo-c source identity')
    host = dv_crate_files(bodies['cargoCSource'],'cargo-c','0.10.26+cargo-0.100.0')
    dv_need(host.get('Cargo.lock') == bodies['cargoCPackageLock'] and dv_hash(bodies['cargoCPackageLock'])==DOVI_CARGO_C_LOCK_SHA,
            'authentic packaged cargo-c lock correspondence')
    vcs = dv_json(host['.cargo_vcs_info.json'])
    dv_need(vcs.get('git',{}).get('sha1') == DOVI_CARGO_C_COMMIT, 'cargo-c package/Git provenance')
    host_manifest = tomllib.loads(host['Cargo.toml'].decode())
    dv_need(host_manifest['package']['name'] == 'cargo-c' and
            host_manifest['package']['version'] == '0.10.26+cargo-0.100.0', 'cargo-c packaged version')
    dv_need(type(pins.get('schema')) is int and pins.get('schema') == 1 and pins.get('profile') == DOVI_SOURCE_PROFILE and
            pins.get('sourceCommit') == DOVI_SOURCE_COMMIT and pins.get('cargoCCommit') == DOVI_CARGO_C_COMMIT,
            'exact input selection')
    dv_need(pins.get('admissionReceiptPath')==str(work/'dist/dovi-inputs/admission.json') and
            pins.get('vendorRoot')==str(work/'dist/dovi-inputs/vendor') and
            pins.get('cargoCRoot')==str(work/'dist/dovi-inputs/cargo-c-install'),'owned fixed admission/vendor/host-tool roots')
    payload = {key:value for key,value in pins.items() if key not in ('admissionReceiptPath','admissionReceiptSHA256')}
    payload_sha = dv_hash(json.dumps(payload,sort_keys=True,separators=(',',':')).encode())
    dv_need(admission.get('profile') == DOVI_SOURCE_PROFILE and admission.get('inputsPayloadSHA256') == payload_sha and
            admission.get('sourceInputsAccepted') is True and pins.get('admissionReceiptSHA256') == dv_hash(bodies['admission']),
            'real independent admission receipt binding')
    roots = {key:dv_path(pins[key],True) for key in ('toolchainRoot','cargoCRoot','vendorRoot')}
    dv_need(roots['toolchainRoot'].name == 'nightly-2026-07-19-aarch64-apple-darwin', 'real pinned nightly route')
    fixed = {'bin/rustc':'caa545e7a0443d8c3a58e2f8cc0dbb3aac00a9e157b722da01c633271fe45687',
             'bin/cargo':'15d061d140be9e57ee7768d7897c473d4d7488c2b7f52f849953b9e58ab88080',
             'lib/rustlib/multirust-channel-manifest.toml':'f94158eb7d97e7ba5ea73e500c46ea48268aeb12d2cc28a40566a004b85861a8',
             'lib/rustlib/src/rust/library/Cargo.lock':DOVI_STD_LOCK_SHA}
    for family in ('toolchainNodes','cargoCNodes','vendorNodes'):
        ledger = pins.get(family)
        dv_need(type(ledger) is list and 0 < len(ledger) <= 100000, 'complete provider node ledger')
        seen = set()
        for node in ledger:
            dv_path(node['path']); dv_need(node['path'] not in seen and type(node.get('mode')) is int,'provider node identity')
            seen.add(node['path'])
            dv_need(node.get('type') in ('file','directory','symlink'), 'provider node kind')
            if node['type'] == 'file':
                dv_need(type(node.get('bytes')) is int and 0 <= node['bytes'] <= 1024**3 and re.fullmatch('[0-9a-f]{64}',node.get('sha256','')), 'provider file identity')
        dv_need([node['path'] for node in ledger] == sorted(seen), 'canonical complete provider ledger')
    by_path = {node['path']:node for node in pins['toolchainNodes']}
    dv_need(all(by_path.get(name,{}).get('sha256') == checksum for name,checksum in fixed.items()), 'compiler/source candidate bytes')
    tool_binary = next((node for node in pins['cargoCNodes'] if node['path'] == 'bin/cargo-cinstall'),None)
    host_build = dv_json(bodies['hostToolBuild'])
    dv_need(tool_binary is not None and tool_binary.get('mode',0) & 0o111 and type(host_build.get('schema')) is int and host_build.get('schema') == 1 and
            host_build.get('sourceCrateSHA256') == DOVI_CARGO_C_SHA and host_build.get('packageLockSHA256') == dv_hash(bodies['cargoCPackageLock']) and
            host_build.get('compilerSHA256') == fixed['bin/rustc'] and host_build.get('cargoCinstallSHA256') == tool_binary['sha256'] and
            host_build.get('compiled') is True and host_build.get('downloadedExecutable') is False and
            host_build.get('globallyInstalled') is False and host_build.get('operatorSHA256')==DOVI_BOOTSTRAP_OPERATOR_SHA==dv_hash(bodies['hostToolOperator']) and
            host_build.get('vendorIndexSHA256')==dv_hash(bodies['vendorIndex']), 'built host tool provenance')
    bootstrap,bootstrap_admission=(dv_json(bodies[key]) for key in ('bootstrapInputs','bootstrapAdmission'))
    dv_need(host_build.get('bootstrapInputsSHA256')==dv_hash(bodies['bootstrapInputs']) and
            host_build.get('bootstrapAdmissionSHA256')==dv_hash(bodies['bootstrapAdmission']) and
            bootstrap_admission.get('scope')=='cargo-c-host-bootstrap-only' and bootstrap_admission.get('sourceInputsAccepted') is True and
            bootstrap_admission.get('inputsSHA256')==dv_hash(bodies['bootstrapInputs']),'actual compiler bootstrap receipt binding')
    for key in ('toolchainRoot','toolchainNodes','vendorNodes','appleTools','hostNativeTools','sdks','sandboxExec'):
        dv_need(dv_equal(bootstrap[key],pins[key]),'host bootstrap/final provider conservation')
    source=work/'dist/dovi-inputs/host-source/cargo-c-0.10.26+cargo-0.100.0';target=work/'dist/dovi-inputs/host-target'
    expected_command=[str(roots['toolchainRoot']/'bin/cargo'),'build','--frozen','--offline','--release','--features=vendored-openssl','--bin=cargo-cinstall','-j1',
      '--manifest-path='+str(source/'Cargo.toml'),'--target-dir='+str(target),'-vv']
    dv_need(host_build.get('sourceDirectory')==str(source) and host_build.get('command')==expected_command,
            'exact source-only frozen/offline host tool build route')
    sandbox=pins.get('sandboxExec',{})
    dv_need(type(sandbox) is dict and set(sandbox)=={'path','sha256'} and sandbox['path']=='/usr/bin/sandbox-exec' and
            re.fullmatch('[0-9a-f]{64}',sandbox['sha256']),'fixed OS sandbox provider')
    envelope=[sandbox['path'],'-D','SOURCE='+str(source),'-D','VENDOR='+str(roots['vendorRoot']),'-D','TOOLCHAIN='+str(roots['toolchainRoot']),'-p',DOVI_SANDBOX_PROFILE]
    dv_need(host_build.get('executionCommand')==envelope+expected_command and
            host_build.get('executionTimeoutSeconds')==600 and type(host_build.get('executionTimeoutSeconds')) is int and
            host_build.get('sandboxProfileSHA256')==dv_hash(DOVI_SANDBOX_PROFILE.encode()),'finite host build network/source-write sandbox')
    host_env=host_build.get('environment',{})
    tools=dict(pins['appleTools'],**pins['hostNativeTools'])
    dv_need(set(pins['appleTools'])=={'clang','ar'} and set(pins['hostNativeTools'])=={'clangxx','cmake','make','perl','ranlib'},'exact host native-tool selection')
    host_linker=str(dv_path(tools['clang']['path'],True));host_sdk=pins['sdks']['macosx']['selectedRoot']
    host_flags=shlex.join(['--target=arm64-apple-macos12.0','-isysroot',host_sdk])
    expected_host_env={'PATH':str(roots['toolchainRoot']/'bin')+':/usr/bin:/bin','LC_ALL':'C',
      'CARGO_HOME':str(work/'dist/dovi-inputs/host-cargo-home'),'CARGO_TARGET_DIR':str(target),
      'CARGO':str(roots['toolchainRoot']/'bin/cargo'),'RUSTC':str(roots['toolchainRoot']/'bin/rustc'),'RUSTDOC':str(roots['toolchainRoot']/'bin/rustdoc'),
      'CARGO_NET_OFFLINE':'true','CARGO_BUILD_JOBS':'1','CARGO_INCREMENTAL':'0','CARGO_PROFILE_RELEASE_CODEGEN_UNITS':'1',
      'CARGO_ENCODED_RUSTFLAGS':'\x1f'.join(['-Zthreads=1','-Ccodegen-units=1','-Clinker='+host_linker,'-Clink-arg=-isysroot','-Clink-arg='+host_sdk]),
      'CARGO_PROFILE_RELEASE_PANIC':'abort','CARGO_TARGET_AARCH64_APPLE_DARWIN_LINKER':host_linker,
      'NUM_JOBS':'1','MAKEFLAGS':'-j1','CMAKE_BUILD_PARALLEL_LEVEL':'1','SDKROOT':host_sdk,'MACOSX_DEPLOYMENT_TARGET':'12.0',
      'CC':host_linker,'CXX':tools['clangxx']['path'],'AR':tools['ar']['path'],'RANLIB':tools['ranlib']['path'],
      'CFLAGS':host_flags,'CPPFLAGS':host_flags,'CXXFLAGS':host_flags,'ASMFLAGS':host_flags,
      'CMAKE':tools['cmake']['path'],'MAKE':tools['make']['path'],'PERL':tools['perl']['path'],
      'PKG_CONFIG':'/usr/bin/false','PKG_CONFIG_LIBDIR':'','PKG_CONFIG_PATH':'','DYLD_LIBRARY_PATH':str(roots['toolchainRoot']/'lib')}
    dv_need(dv_equal(host_env,expected_host_env),'exact canonical Rust host linker and closed bootstrap environment')
    expected_crates = {}
    for key in ('libraryLock','stdLock','cargoCPackageLock'):
        for crate, checksum in dv_lock(bodies[key]).items():
            dv_need(crate not in expected_crates or expected_crates[crate] == checksum,'conflicting locked crate identity')
            expected_crates[crate] = checksum
    vendor = dv_json(bodies['vendorIndex'])
    dv_need(type(vendor) is list and len(vendor) == len(expected_crates), 'exact library/std/host-tool registry union')
    observed = {}
    for row in vendor:
        dv_need(type(row) is dict and set(row) == {'name','version','checksum','path','bytes','sha256','checksumFile'}, 'vendor crate row')
        key = (row['name'],row['version']); expected_path = 'crates/' + row['name'] + '-' + row['version'] + '.crate'
        dv_need(key not in observed and expected_crates.get(key) == row['checksum'] == row['sha256'] and
                row['path'] == expected_path and type(row['bytes']) is int and 0 < row['bytes'] <= 64*1024**2, 'exact compressed vendor provider')
        observed[key] = row
    dv_need(set(observed) == set(expected_crates), 'complete registry union')
    return pins, mapping, vendor, bodies


def dv_vendor_binding(vendor_tar, expected, pins):
    """Bind every actual extracted vendor file to authenticated registry bytes."""
    wanted = {row['path']:row for row in expected}; seen = set(); total = 0
    dv_need(all(row['type'] in ('file','directory') for row in pins['vendorNodes']), 'vendor links or special nodes')
    ledger = {row['path']:row for row in pins['vendorNodes'] if row['type'] == 'file'}
    proved = set()
    with tarfile.open(fileobj=io.BytesIO(vendor_tar),mode='r:') as archive:
        for item in archive:
            dv_need(item.isfile() and item.name in wanted and item.name not in seen and item.size == wanted[item.name]['bytes'], 'vendor capture member')
            with archive.extractfile(item) as stream: body = stream.read(item.size+1)
            row = wanted[item.name]; dv_need(len(body)==item.size and dv_hash(body)==row['checksum'],'vendor compressed checksum')
            total += len(body); dv_need(total <= 2*1024**3,'compressed vendor capture cap'); seen.add(item.name)
            members = dv_crate_files(body,row['name'],row['version']); prefix = row['name']+'-'+row['version']+'/'
            for name, raw in members.items():
                node = ledger.get(prefix+name,{})
                dv_need(node.get('bytes')==len(raw) and node.get('sha256')==dv_hash(raw),'extracted vendor/crate body correspondence')
                proved.add(prefix+name)
            check_name = prefix+'.cargo-checksum.json'; check_row=ledger.get(check_name,{})
            # Bind actual checksum-file bytes, then derive the semantic content.
            # Formatting/order are not an ABI or package identity requirement.
            check = {'files':{name:dv_hash(raw) for name,raw in members.items()},'package':row['checksum']}
            check_body=dv_inline(row['checksumFile'],[0],4*1024**2)
            dv_need(row['checksumFile']['path']=='vendor/'+check_name and check_row.get('bytes')==len(check_body) and
                    check_row.get('sha256')==dv_hash(check_body) and dv_json(check_body)==check,'actual cargo checksum manifest/file correspondence')
            proved.add(check_name)
    dv_need(seen==set(wanted) and proved==set(ledger),'complete exact vendor capture/file closure')


def dv_macho(body, arch, platform, minimum, sdk, *, probe=False, rust_cgu=False):
    dv_need(len(body)>=32 and body[:4]==b'\xcf\xfa\xed\xfe','64-bit little-endian Mach-O object')
    cpu,subtype,kind,count,command_bytes,flags,reserved=struct.unpack_from('<7I',body,4)
    expected_cpu = 0x01000007 if arch=='x86_64' else 0x0100000c
    expected_subtype = 3 if arch=='x86_64' else 2 if arch=='arm64e' else 0
    dv_need(cpu==expected_cpu and subtype & 0xffffff==expected_subtype and kind==1 and count<=8192 and 32+command_bytes<=len(body),'real object CPU/subtype/type')
    position=32; versions=[]; symbols=[]; weak_symbols=[]; functions=[]; sections=[]; section_kinds=[]; symbol_command=None
    for _ in range(count):
        dv_need(position+8<=32+command_bytes,'load command header'); command,size=struct.unpack_from('<II',body,position)
        dv_need(size>=8 and position+size<=32+command_bytes,'load command bound')
        if command==0x32:
            dv_need(size>=24,'build version command'); p,low,high,tools=struct.unpack_from('<4I',body,position+8); versions.append((p,low,high))
        if command in (0x24,0x25,0x2f,0x30): dv_need(False,'legacy/ambiguous minimum-version command')
        if command==2:
            dv_need(symbol_command is None and size==24,'symbol table command'); symbol_command=struct.unpack_from('<4I',body,position+8)
        if command==0x19:
            dv_need(size>=72,'segment command'); nsects=struct.unpack_from('<I',body,position+64)[0]
            dv_need(72+80*nsects==size,'section command length')
            for index in range(nsects):
                base=position+72+80*index; name=body[base:base+16].split(b'\0')[0]; addr,length,offset=struct.unpack_from('<QQI',body,base+32)
                section_flags=struct.unpack_from('<I',body,base+64)[0];section_kinds.append((name,section_flags))
                if offset and length: dv_need(offset+length<=len(body),'section body bound'); sections.append((name,body[offset:offset+length]))
        position+=size
    dv_need(position==32+command_bytes and len(versions)==1 and versions[0][0]==platform and versions[0][1]==minimum,'exact object platform/minimum')
    # A zero SDK stamp is admitted only for a named Rust codegen-unit object,
    # whose source/compiler/command/provider closure is separately byte-bound.
    # Every native C object and the C ABI probe must stamp the exact SDK.
    dv_need(versions[0][2]==sdk or (not probe and rust_cgu and versions[0][2]==0),'object SDK identity')
    if symbol_command:
        start,number,strings,string_bytes=symbol_command
        dv_need(number<=2000000 and start+16*number<=len(body) and strings+string_bytes<=len(body),'symbol table bounds')
        for index in range(number):
            name_index,ntype,nsect,desc,value=struct.unpack_from('<IBBHQ',body,start+16*index)
            if not ntype & 0xe0 and ntype & 1 and ntype & 0xe==0xe and nsect:
                dv_need(name_index<string_bytes,'symbol string offset'); end=body.find(b'\0',strings+name_index,strings+string_bytes); dv_need(end>=0,'symbol string termination')
                name=body[strings+name_index:end].decode('utf-8').removeprefix('_'); symbols.append(name)
                if desc & 0x80: weak_symbols.append(name)
                dv_need(0<nsect<=len(section_kinds),'defined symbol section index')
                section_name,section_flags=section_kinds[nsect-1]
                if section_name==b'__text' and section_flags & (0x80000000|0x400): functions.append(name)
    if probe:
        expected=struct.pack('<10Q',0x564f525458444f56,16,8,0,8,24,8,0,8,16)
        dv_need(sum(raw.count(expected) for _,raw in sections)==1,'compiled C ABI sizeof/alignment/offset probe')
    return {'cpuSubtype':subtype,'platform':versions[0][0],'minimum':versions[0][1],'sdk':versions[0][2],
            'defined':sorted(symbols),'definedFunctions':sorted(functions),'weakDefined':sorted(weak_symbols)}


def dv_archive(body, arch, platform, minimum, sdk, required):
    dv_need(isinstance(body,bytes) and 8<len(body)<=512*1024**2 and body.startswith(b'!<arch>\n'),'static archive format/bound')
    position=8; members=[]; metadata=[]; owners={name:0 for name in required}; ordinal=0
    while position<len(body):
        dv_need(position+60<=len(body),'archive header bound'); header=body[position:position+60]; dv_need(header[58:60]==b'`\n','archive header trailer')
        try: size=int(header[48:58].strip()); name=header[:16].decode('ascii').strip()
        except (ValueError,UnicodeError) as error: raise ValueError('libdovi: archive header encoding') from error
        start=position+60; end=start+size; dv_need(size>=0 and end<=len(body),'archive member bound'); raw=body[start:end]
        if name.startswith('#1/'):
            n=int(name[3:]); dv_need(0<n<=4096 and n<=len(raw),'BSD member name bound'); name=raw[:n].rstrip(b'\0').decode('utf-8'); raw=raw[n:]
        name=name.rstrip('/'); ordinal+=1; dv_need(ordinal<=100000,'archive member count')
        row={'ordinal':ordinal,'name':name,'bytes':len(raw),'sha256':dv_hash(raw)}
        if name.startswith('__.SYMDEF') or name in ('','/'):
            metadata.append(row)
        else:
            observed=dv_macho(raw,arch,platform,minimum,sdk,rust_cgu=bool(re.fullmatch(r'[A-Za-z0-9_.-]+\.rcgu\.o',name)))
            for symbol in observed['defined']:
                if symbol in owners:
                    dv_need(symbol in observed['definedFunctions'] and symbol not in observed['weakDefined'],'required API is not a strong code definition')
                    owners[symbol]+=1
            row['object']=observed; members.append(row)
        position=end+(size&1)
    dv_need(position==len(body) and members and all(value==1 for value in owners.values()),'complete archive and sole required C API owners')
    return {'members':members,'metadataMembers':metadata,'requiredSymbolOwners':owners,
            'sdkUnstampedObjects':sum(row['object']['sdk']==0 for row in members)}


def dv_version(value):
    parts=value.split('.'); dv_need(1<=len(parts)<=3 and all(part.isdigit() and int(part)<256 for part in parts),'SDK numeric version')
    numbers=[int(part) for part in parts]+[0]*3
    return numbers[0]<<16|numbers[1]<<8|numbers[2]


def dv_public(header, pc, prefix, native_libraries, required):
    text=header.decode('utf-8'); config=pc.decode('utf-8')
    dv_need('#ifndef DOVI_H' in text and '#define DOVI_H' in text and 'SPDX-License-Identifier: MIT' in text,'generated public header identity')
    dv_need(all(len(re.findall(r'\b'+re.escape(name)+r'\s*\(',text))==1 for name in required),'exact required C API declarations')
    fields={}; variables={}
    for line in config.splitlines():
        if not line.strip() or line.startswith('#'): continue
        if ':' in line and ('=' not in line or line.index(':')<line.index('=')):
            key,value=line.split(':',1); dv_need(key not in fields,'duplicate PC field'); fields[key]=value.strip()
        elif '=' in line:
            key,value=line.split('=',1); dv_need(key not in variables,'duplicate PC variable'); variables[key]=value.strip()
        else: dv_need(False,'unknown PC line')
    dv_need(fields.get('Version')=='3.4.0' and variables.get('prefix')==str(prefix),'exact PC version/prefix')
    dv_need(not fields.get('Requires') and not fields.get('Requires.private'),'unexpected PC dependency')
    tokens=shlex.split(fields.get('Libs.private','')); dv_need(len(tokens)==len(set(tokens)) and set(tokens)<=set(native_libraries),'PC SDK static provider set')
    libs=shlex.split(fields.get('Libs','')); dv_need(len(libs)>=2 and libs[:2] in (['-L${libdir}','-ldovi'],['-L'+str(prefix/'lib'),'-ldovi']),'exact dovi archive linker selection')
    public_native=libs[2:]
    dv_need(len(public_native)==len(set(public_native)) and set(public_native)<=set(native_libraries)
            and set(public_native)<=set(tokens),'public SDK flags must be unique and already validated privately')
    dv_need(variables.get('libdir') in ('${prefix}/lib',str(prefix/'lib')) and variables.get('includedir') in ('${prefix}/include',str(prefix/'include')),'target PC directory variables')
    dv_need(shlex.split(fields.get('Cflags','')) in (['-I${includedir}'],['-I'+str(prefix/'include')]),'target PC include selection')
    return tokens


def dv_sdk(pins, sdk_bodies, budget):
    expected={row[3] for row in DOVI_MATRIX}
    dv_need(type(pins.get('sdks')) is dict and set(pins['sdks'])==expected and set(sdk_bodies)==expected,'exact selected SDK family')
    stems={'iphoneos':'iPhoneOS','iphonesimulator':'iPhoneSimulator','appletvos':'AppleTVOS','appletvsimulator':'AppleTVSimulator','macosx':'MacOSX'}
    allowed={'-liconv':'/usr/lib/libiconv.2.dylib','-lSystem':'/usr/lib/libSystem.B.dylib','-lc':'/usr/lib/libSystem.B.dylib','-lm':'/usr/lib/libSystem.B.dylib'}
    for name,sdk in pins['sdks'].items():
        selected=dv_path(sdk['selectedRoot'],True); resolved=dv_path(sdk['resolvedRoot'],True)
        dv_need(selected.suffix=='.sdk' and resolved.suffix=='.sdk' and
                selected.name.startswith(stems[name]) and resolved.name.startswith(stems[name]),'SDK selected/canonical spelling')
        expected_files={row['path']:row for row in sdk['files']}
        dv_need(len(expected_files)==len(sdk['files']) and set(sdk_bodies[name])==set(expected_files) and
                {'SDKSettings.json','usr/lib/libSystem.tbd'}<=set(expected_files),'SDK provider file set')
        bodies={rel:dv_inline(row,budget,4*1024**2) for rel,row in sdk_bodies[name].items()}
        for rel,body in bodies.items():
            dv_path(rel)
            dv_need(sdk_bodies[name][rel]['path']=='sdk/'+name+'/'+rel and dv_hash(body)==expected_files[rel]['sha256'],'SDK raw provider correspondence')
        settings=dv_json(bodies['SDKSettings.json'])
        dv_need(str(settings.get('Version'))==sdk['version'],'SDK version metadata')
        dv_version(sdk['version'])
        libraries=sdk.get('nativeLibraries')
        dv_need(type(libraries) is dict and '-lSystem' in libraries and set(libraries)<=set(allowed),'SDK native static provider policy')
        for flag,relative in libraries.items():
            dv_need(relative in bodies and relative.startswith('usr/lib/') and relative.endswith('.tbd'),'SDK native stub path')
            text=bodies[relative].decode('utf-8')
            dv_need(text.startswith('--- !tapi-tbd') and allowed[flag] in text,'SDK native stub identity')
    return pins['sdks']


def dv_row(value, inputs, policy, work, identity, budget, archive_body=None):
    platform,arch,target,sdk_name,floor_var,floor,clang_target,slice_name,platform_id=identity
    dv_need(type(value) is dict and set(value)=={'platform','arch','slice','record','header','pkgConfig','cargoLog','abiSource','abiObject','consumerRecord','consumerDependencies','consumerArchive','archive'},'build row shape')
    dv_need((value['platform'],value['arch'],value['slice'])==(platform,arch,slice_name),'ordered target matrix')
    raw={name:dv_inline(value[name],budget,16*1024**2) for name in ('record','header','pkgConfig','cargoLog','abiSource','abiObject','consumerRecord','consumerDependencies')}
    record=dv_json(raw['record']); prefix=work/'dist/libdovi'/platform/'thin'/arch; scratch=work/'dist/libdovi'/platform/'scratch'/arch
    expected_paths={'header':prefix/'include/libdovi/rpu_parser.h','pkgConfig':prefix/'lib/pkgconfig/dovi.pc',
      'abiSource':scratch/'dovi-api-abi.c','abiObject':scratch/'dovi-api-abi.o',
      'consumerRecord':work/'dist/libplacebo'/platform/'scratch'/arch/'vortx-dovi-consumer.json',
      'consumerDependencies':work/'dist/libplacebo'/platform/'scratch'/arch/'meson-info/intro-dependencies.json'}
    dv_need(all(value[key]['path']==path.relative_to(work).as_posix() for key,path in expected_paths.items()),'exact target public/probe/consumer file paths')
    pins=inputs; tool=dv_path(pins['toolchainRoot'],True); cargo_c=dv_path(pins['cargoCRoot'],True)/'bin/cargo-cinstall'; sdk=pins['sdks'][sdk_name]
    selected=dv_path(sdk['selectedRoot'],True); home=scratch/'cargo-home'
    command=[str(cargo_c),'cinstall','--frozen','--offline','-j1','-Zbuild-std=std,panic_abort','--release','--library-type=staticlib','--no-default-features','--features=capi',
             '--manifest-path='+str(work/'dist'/DOVI_SOURCE_ROOT/'dolby_vision/Cargo.toml'),'--target='+target,'--target-dir='+str(scratch/'target'),'--prefix='+str(prefix),'--libdir=lib','-vv']
    flags=shlex.join(['-target',clang_target,'-isysroot',str(selected)])
    tools=pins['appleTools']; dv_need(set(tools)=={'clang','ar'},'fixed Apple compile tools')
    expected_env={'PATH':str(tool/'bin')+':/usr/bin:/bin','LC_ALL':'C','CARGO_HOME':str(home),
       'CARGO':str(tool/'bin/cargo'),'CARGO_C_CARGO':str(tool/'bin/cargo'),'RUSTC':str(tool/'bin/rustc'),'RUSTDOC':str(tool/'bin/rustdoc'),
       'CARGO_BUILD_JOBS':'1','CARGO_INCREMENTAL':'0','CARGO_NET_OFFLINE':'true','CARGO_PROFILE_RELEASE_CODEGEN_UNITS':'1',
       'CARGO_ENCODED_RUSTFLAGS':'\x1f'.join(['-Zthreads=1','-Ccodegen-units=1','-Clinker='+tools['clang']['path']]),
       'CARGO_TARGET_AARCH64_APPLE_DARWIN_LINKER':tools['clang']['path'],'NUM_JOBS':'1','MAKEFLAGS':'-j1','CARGO_TARGET_DIR':str(scratch/'target'),
       'CARGO_PROFILE_RELEASE_PANIC':'abort','SDKROOT':str(selected),floor_var:floor,'CC':tools['clang']['path'],'AR':tools['ar']['path'],
       'CFLAGS':flags,'CXXFLAGS':flags,'CPPFLAGS':flags,'ASMFLAGS':flags,'DYLD_LIBRARY_PATH':str(tool/'lib')}
    expected_keys={'schema','profile','version','sourceCommit','platform','arch','rustTarget','clangTarget','sourceInputsSHA256','sourceMapSHA256','command','executionCommand','executionTimeoutSeconds','sandboxProfileSHA256','environment','logSHA256','outputs','compiled','installed','archiveInspectionAccepted','apiAbiAccepted','sdkAccepted','shippingAccepted','apiProbe'}
    dv_need(type(record) is dict and set(record)==expected_keys,'exact producer record shape')
    fixed={'schema':1,'profile':DOVI_SOURCE_PROFILE,'version':'3.4.0','sourceCommit':DOVI_SOURCE_COMMIT,'platform':platform,'arch':arch,'rustTarget':target,'clangTarget':clang_target,
       'sourceInputsSHA256':policy['inputsSHA256'],'sourceMapSHA256':DOVI_MAP_SHA,'command':command,'environment':expected_env,'logSHA256':dv_hash(raw['cargoLog']),
       'compiled':True,'installed':True,'archiveInspectionAccepted':False,'apiAbiAccepted':False,'sdkAccepted':False,'shippingAccepted':False}
    dv_need(all(record.get(key)==item and type(record.get(key)) is type(item) for key,item in fixed.items()),'actual source/command/environment/open-gate correspondence')
    envelope=dovi_library_envelope(work,pins)
    dv_need(record['executionCommand']==envelope+command and record['executionTimeoutSeconds']==600 and type(record['executionTimeoutSeconds']) is int and
            record['sandboxProfileSHA256']==dv_hash(DOVI_LIBRARY_SANDBOX_PROFILE.encode()),'finite library build network/source-write sandbox')
    dv_need(value['record']['path']==str((scratch/'vortx-dovi-build.json').relative_to(work)) and value['cargoLog']['path']==str((scratch/'cargo-cinstall.log').relative_to(work)),'record/log target path')
    expected_out={str((prefix/'include/libdovi/rpu_parser.h').relative_to(work)):raw['header'],str((prefix/'lib/pkgconfig/dovi.pc').relative_to(work)):raw['pkgConfig']}
    archive=value['archive']; dv_need(type(archive) is dict and set(archive)=={'path','bytes','sha256','inspection'},'archive row shape')
    dv_need(archive['path']==str((prefix/'lib/libdovi.a').relative_to(work)) and type(archive['bytes']) is int and 0<archive['bytes']<=512*1024**2 and re.fullmatch('[0-9a-f]{64}',archive['sha256']),'thin archive identity')
    outputs={row['path']:row for row in record['outputs']}
    dv_need(type(record['outputs']) is list and len(record['outputs'])==3 and len(outputs)==3 and set(outputs)==set(expected_out)|{archive['path']},'exact installed provider set')
    for name,body in expected_out.items(): dv_need(outputs[name]=={'path':name,'bytes':len(body),'sha256':dv_hash(body)},'actual installed public files')
    dv_need(outputs[archive['path']]=={key:archive[key] for key in ('path','bytes','sha256')},'actual archive output binding')
    native_flags=dv_public(raw['header'],raw['pkgConfig'],prefix,sdk['nativeLibraries'],policy['requiredSymbols'])
    dv_need(dv_hash(raw['abiSource'])==policy['abiProbeSourceSHA256'],'fixed real C API/ABI probe source')
    api_command=[tools['clang']['path'],'-target',clang_target,'-isysroot',str(selected),'-std=c11','-Werror','-fno-common','-I'+str(prefix/'include'),'-c',str(scratch/'dovi-api-abi.c'),'-o',str(scratch/'dovi-api-abi.o')]
    dv_need(record['apiProbe']=={'command':api_command,'executionCommand':envelope+api_command,'executionTimeoutSeconds':60,'sourceSHA256':dv_hash(raw['abiSource']),'objectSHA256':dv_hash(raw['abiObject'])},'actual finite C API probe command/provider')
    probe=dv_macho(raw['abiObject'],arch,platform_id,dv_version(floor),dv_version(sdk['version']),probe=True)
    if archive_body is not None:
        dv_need(len(archive_body)==archive['bytes'] and dv_hash(archive_body)==archive['sha256'],'actual archive bytes')
        inspected=dv_archive(archive_body,arch,platform_id,dv_version(floor),dv_version(sdk['version']),policy['requiredSymbols'])
        dv_need(dv_equal(inspected,archive['inspection']),'independently derived archive object/symbol evidence')
        dv_need(all(member['object']['cpuSubtype']==probe['cpuSubtype'] for member in inspected['members']),'Rust/C probe CPU subtype/ARM64e ABI agreement')
    consumer=dv_json(raw['consumerRecord']); dependencies=dv_json(raw['consumerDependencies'])
    consumer_archive=value['consumerArchive']
    dv_need(type(consumer_archive) is dict and set(consumer_archive)=={'path','bytes','sha256'} and
            consumer_archive['path']==str((work/'dist/libplacebo'/platform/'thin'/arch/'lib/libplacebo.a').relative_to(work)) and
            type(consumer_archive['bytes']) is int and 0<consumer_archive['bytes']<=512*1024**2 and re.fullmatch('[0-9a-f]{64}',consumer_archive['sha256']),'actual consumer archive identity')
    expected={'schema':1,'sourceCommit':'275f7dea27924cdd34ab2e6c20e448b6bc4fab65','platform':platform,'arch':arch,
              'providerArchiveSHA256':archive['sha256'],'providerHeaderSHA256':dv_hash(raw['header']),'providerPcSHA256':dv_hash(raw['pkgConfig']),
              'dependencyBytesSHA256':dv_hash(raw['consumerDependencies']),'consumerArchiveSHA256':consumer_archive['sha256'],
              'consumerArchiveBytes':consumer_archive['bytes'],'compiled':True,'installed':True}
    dv_need(dv_equal(consumer,expected),'real libplacebo build/selected dovi provider binding')
    selected_deps=[row for row in dependencies if isinstance(row,dict) and row.get('name') in ('dovi','libdovi')]
    dv_need(len(selected_deps)==1 and selected_deps[0].get('version')=='3.4.0','actual Meson selected dovi dependency')
    dep=selected_deps[0]; include='-I'+str(prefix/'include'); link=dep.get('link_args',[])
    dv_need(dep.get('compile_args')==[include] and isinstance(link,list) and
            (str(prefix/'lib/libdovi.a') in link or ('-L'+str(prefix/'lib') in link and '-ldovi' in link)) and
            all(flag in native_flags or flag in ('-L'+str(prefix/'lib'),'-ldovi',str(prefix/'lib/libdovi.a')) for flag in link),'sole target static dovi dependency flags')
    return archive


def dv_fat(body, expected):
    if body.startswith(b'!<arch>\n'):
        dv_need(len(expected)==1,'thin archive for multi-arch framework')
        return {next(iter(expected)):body}
    dv_need(len(body)>=8,'fat archive header')
    magic=int.from_bytes(body[:4],'big'); endian='>'
    if magic in (0xbebafeca,0xbfbafeca): magic=int.from_bytes(body[:4],'little'); endian='<'
    dv_need(magic in (0xcafebabe,0xcafebabf),'fat archive magic'); wide=magic==0xcafebabf
    count=struct.unpack_from(endian+'I',body,4)[0]; width=32 if wide else 20
    dv_need(0<count<=16 and 8+count*width<=len(body),'fat count/bounds'); result={};ranges=[]
    for index in range(count):
        start=8+index*width; cpu,subtype=struct.unpack_from(endian+'II',body,start)
        offset,size,align=struct.unpack_from(endian+('QQI' if wide else 'III'),body,start+8)
        arch='x86_64' if cpu==0x01000007 and subtype&0xffffff==3 else ('arm64e' if cpu==0x0100000c and subtype&0xffffff==2 else 'arm64' if cpu==0x0100000c and subtype&0xffffff==0 else None)
        dv_need(arch in expected and arch not in result and 0<size<=512*1024**2 and
                offset>=8+count*width and offset+size<=len(body) and align<=30 and offset%(1<<align)==0,'fat architecture/range/alignment')
        result[arch]=body[offset:offset+size]; ranges.append((offset,offset+size))
    ranges.sort(); dv_need(set(result)==expected and all(end<=start for (_,end),(start,_) in zip(ranges,ranges[1:])),'fat exact architecture set/nonoverlap')
    return result


DOVI_INSTALLED_HELPERS = {'Sources/BuildScripts/dovi-source-build.py': '58b4c20d66fdd6b4f9d2958e12be76f5c078820fda4330053fe5e663bdcadf14', 'Sources/BuildScripts/dovi-source-map.json': '7662a50dee5cf02f35f5da56bed11808fa0e6a7f04c46ddbff05bab8557a30d3', 'Sources/BuildScripts/dovi-source-policy.json': 'f46c891c881f05c904acaf8b36e3127935905c23e9f66706fede0548c5a7de90'}
PLACEBO_INSTALLED_HELPERS = {'Sources/BuildScripts/placebo-source-build.py': 'ed2b5b2c2fd45b6c03b6cf0ea5fc707b080f05bdb6f40dd270594ae2acdca617'}

def dovi_builds_receipt(body, zip_bodies, vendor_tar, native_archive, native_group, package_text):
    """Recompute source/vendor/API/ABI/archive/provider facts without a producer process."""
    dv_require_composition()
    value=dv_json(body)
    dv_need(type(value) is dict and set(value)=={'schemaVersion','profile','sourceProfile','version','work','sourceCommit','sourceInputs','sdkInputs','sourceFiles','policy','vendorCapture','rows','runtimeDolbyVisionTested','promotionEligible'},'BOM exact keys')
    fixed={'schemaVersion':1,'profile':DOVI_PROFILE,'sourceProfile':DOVI_SOURCE_PROFILE,'version':'3.4.0','sourceCommit':DOVI_SOURCE_COMMIT,'runtimeDolbyVisionTested':False,'promotionEligible':False}
    dv_need(all(value.get(key)==item and type(value.get(key)) is type(item) for key,item in fixed.items()),'source identity/open gates')
    work=dv_path(value['work'],True); budget=[0]; policy_body=dv_inline(value['policy'],budget)
    dv_need(dv_hash(policy_body)==DOVI_POLICY_SHA,'immutable source/API policy'); policy=dv_json(policy_body)
    pins,mapping,vendor,bodies=dv_inputs(value['sourceInputs'],budget,work); dv_sdk(pins,value['sdkInputs'],budget)
    policy=dict(policy,inputsSHA256=dv_hash(bodies['inputs']))
    dv_need(value['vendorCapture']=={'path':'dist/dovi-inputs/vendor-crates.tar','bytes':len(vendor_tar),'sha256':dv_hash(vendor_tar)},'actual vendor capture identity')
    dv_vendor_binding(vendor_tar,vendor,pins)
    dv_need(dv_json(bodies['hostToolBuild'])['vendorCaptureSHA256']==dv_hash(vendor_tar),'actual host/current vendor capture conservation')
    # The public Git source inventory is already byte-bound to the captured native
    # tar. Re-read this component's actual bodies to independently derive Git IDs.
    expected={row['path']:row for row in mapping['blobs']}; actual={}; source_rows=[]
    dv_need(native_group['directory']==DOVI_SOURCE_ROOT and native_group['commit']==DOVI_SOURCE_COMMIT and not native_group['gitlinks'],'exact native Git source group')
    root=native_group['root']+'/'
    with tarfile.open(fileobj=io.BytesIO(native_archive),mode='r:gz') as source:
        for member in source:
            if not member.name.startswith(root): continue
            rel=member.name[len(root):]; dv_need(rel in expected and rel not in actual and member.isfile(),'exact dovi native source members')
            with source.extractfile(member) as stream: raw=stream.read(64*1024**2+1)
            pin=expected[rel]; oid=hashlib.sha1(b'blob '+str(len(raw)).encode()+b'\0'+raw).hexdigest()
            dv_need(len(raw)==pin['size'] and oid==pin['sha'] and member.mode==0o644,'official native source blob/mode')
            actual[rel]=raw; source_rows.append({'path':rel,'bytes':len(raw),'sha256':dv_hash(raw),'gitBlobSHA1':oid})
    dv_need(set(actual)==set(expected),'all209 genuine source bodies')
    declared={row['path']:row for row in value['sourceFiles']}; dv_need(len(value['sourceFiles'])==209 and len(declared)==209 and all(dv_equal(declared[row['path']],row) for row in source_rows),'source inventory/raw Git correspondence')
    dv_need(actual['dolby_vision/Cargo.lock']==bodies['libraryLock'],'nested library lock/source body')
    catalog=crypto_zip_catalog(zip_bodies,(('Libdovi','libdovi','libdovi.a','Libdovi'),('Libplacebo','libplacebo','libplacebo.a','Libplacebo')))
    dv_need(type(value['rows']) is list and len(value['rows'])==9,'exact nine build leaves')
    header_hashes=set()
    for row,identity in zip(value['rows'],DOVI_MATRIX,strict=True):
        platform,arch,_,_,_,_,_,slice_name,_=identity
        framework='Libdovi.xcframework/'+slice_name+'/Libdovi.framework/'
        binary=crypto_zip_file(catalog,'Libdovi',framework+'Libdovi')
        arches={entry[1] for entry in DOVI_MATRIX if entry[7]==slice_name}; thin=dv_fat(binary,arches)[arch]
        dv_row(row,pins,policy,work,identity,budget,thin)
        consumer_framework='Libplacebo.xcframework/'+slice_name+'/Libplacebo.framework/'
        consumer_binary=crypto_zip_file(catalog,'Libplacebo',consumer_framework+'Libplacebo')
        consumer_thin=dv_fat(consumer_binary,arches)[arch]
        dv_need(row['consumerArchive']['bytes']==len(consumer_thin) and row['consumerArchive']['sha256']==dv_hash(consumer_thin),'actual rebuilt Libplacebo/provider selection archive')
        _,_,_,sdk_name,_,floor,_,_,platform_id=identity
        other=dv_archive(consumer_thin,arch,platform_id,dv_version(floor),dv_version(pins['sdks'][sdk_name]['version']),())
        dv_need(all(not (set(member['object']['defined']) & set(policy['requiredSymbols'])) for member in other['members']),
                'hidden duplicate dovi C API provider in rebuilt Libplacebo')
        packaged_header=crypto_zip_file(catalog,'Libdovi',framework+'Headers/libdovi/rpu_parser.h',4*1024**2)
        raw_header=dv_inline(row['header'],budget,4*1024**2)
        dv_need(packaged_header==raw_header,'actual local framework/header provider')
        header_hashes.add(dv_hash(packaged_header)); crypto_framework_layout('Libdovi','Libdovi',slice_name,catalog)
    dv_need(len(header_hashes)==1,'one coherent public C header across all targets')
    matches=re.findall(r'\.binaryTarget\(\s*name:\s*"Libdovi",\s*path:\s*"artifacts/Libdovi\.xcframework"\s*\)',package_text)
    dv_need(len(matches)==1 and not re.search(r'name:\s*"Libdovi",\s*url:',package_text),'sole actual local Libdovi target, no retained remote wrapper')
    dv_need(body==(json.dumps(value,indent=2,sort_keys=True)+'\n').encode() and len(body)<=DOVI_LIMIT,'canonical bounded BOM')
    return value


def apple(archive, native, captured, recipe, archive_sources,
          subtitle_archive_sources, source_groups):
    gate = read(archive, "apple-artifact-gate.txt", MIB).decode("utf-8")
    need("TLS VERIFY PASSED: 5 Apple slices and 9 architectures use SecureTransport" in gate.splitlines() and
         "MPVKit-DVFEL ARTIFACT VERIFY PASSED: FFmpeg 9.0.2 (libavcodec/libavformat 63.1.102), dovi_split, and Apple TLS gates" in gate.splitlines() and
         "PASS dependency-profile " + NATIVE_UPGRADES_PROFILE in gate.splitlines() and
         "PASS openssl-profile " + OPENSSL_BOM_PROFILE in gate.splitlines() and
         "PASS apple-openssl-receipt" in gate.splitlines() and
         "PASS apple-shaderc-receipt" in gate.splitlines() and
         "PASS " + CRYPTO_SOURCE_PROFILE + " verify" in gate.splitlines() and
         "PASS crypto-chain archive/public-symbol correspondence; native SMB/runtime gates OPEN" in gate.splitlines() and
         "PASS " + SUBTITLE_SOURCE_PROFILE + " verify" in gate.splitlines() and
         "PASS subtitle-profile " + SUBTITLE_SOURCE_PROFILE in gate.splitlines() and
         "PASS apple-subtitle-receipt" in gate.splitlines() and
         "PASS apple-dovi-receipt" in gate.splitlines() and
         "PASS dovi-profile " + DOVI_SOURCE_PROFILE in gate.splitlines() and
         "PASS apple-sent-abi" in gate.splitlines() and "PASS apple-reference-abi" in gate.splitlines() and
         "FAILED" not in gate, "Apple original, sent-request and finite-reader artifact gates")
    need("apple-shaderc-original-all.zip" in archive.namelist() and
         "apple-shaderc-original-xcframework.zip" in archive.namelist(),
         "Missing Shaderc original output")
    need("apple-shaderc-inputs.json" in archive.namelist(), "Missing Shaderc receipt output")
    need("apple-openssl-builds.json" in archive.namelist(), "Missing OpenSSL BOM output")
    need(all(name in archive.namelist() for name in
             {pin["output"] for pin in CRYPTO_SOURCE_OUTPUTS} |
             {CRYPTO_CAPTURE_TAR_OUTPUT, CRYPTO_CAPTURE_RECEIPT_OUTPUT, CRYPTO_CHAIN_OUTPUT}),
         "Missing crypto source/artifact receipt output")
    need(all(name in archive.namelist() for name in
             {pin["output"] for pin in SUBTITLE_SOURCE_OUTPUTS} |
             {SUBTITLE_CAPTURE_TAR_OUTPUT, SUBTITLE_CAPTURE_RECEIPT_OUTPUT,
              SUBTITLE_BUILD_OUTPUT}),
         "Missing subtitle source/build receipt output")
    shaderc_sources = []
    retained_all_body = None
    for output_name, (source_name, expected_bytes, expected_sha256) in zip(
            ("apple-shaderc-original-all.zip", "apple-shaderc-original-xcframework.zip"),
            SHADERC_SOURCE_SPECS, strict=True):
        data = read(archive, output_name, expected_bytes + 1)
        need(len(data) == expected_bytes and sha(data) == expected_sha256,
             "Exact published Shaderc body: " + output_name)
        shaderc_sources.append(dict(name=source_name, bytes=len(data), sha256=sha(data)))
        if source_name == SHADERC_SOURCE_SPECS[0][0]:
            retained_all_body = data
    need(retained_all_body is not None, "Missing retained Shaderc all-ZIP body")
    with io.BytesIO(retained_all_body) as retained_stream, zip_open(retained_stream) as retained_archive:
        retained_all_rows = zip_index(retained_archive)
    shaderc_receipt(load(read(archive, "apple-shaderc-inputs.json")), shaderc_sources,
                     recipe["scripts/native-media-hosted/evidence.py"], retained_all_rows)
    openssl_bom = load(read(archive, "apple-openssl-builds.json"))
    openssl_receipt(openssl_bom, recipe["scripts/native-media-hosted/evidence.py"])
    subtitle_bom_body = read(archive, SUBTITLE_BUILD_OUTPUT, SUBTITLE_MAX_RECEIPT)
    candidate, actual = tar_index(archive, "apple-candidate.tar.gz", file_limit=512 * MIB, total=4 * 1024**3, capture=("MPVKit-DVFEL/Package.swift",), allow_dirs=True)
    zips, _ = tar_index(archive, "apple-original-library-zips.tar", compressed=False, file_limit=512 * MIB, total=4 * 1024**3, allow_dirs=True)
    need(set(zips) == {name + ".xcframework.zip" for name in LIBRARIES} and all(row["kind"] == "file" for row in zips.values()), "Apple original ZIP set")
    expected = {}
    openssl_zip_bodies = {}
    crypto_zip_bodies = {}
    subtitle_zip_bodies = {}
    dovi_zip_bodies = {}
    # Read each original ZIP through its authenticated tar member, without filesystem extraction.
    with archive.open("apple-original-library-zips.tar") as stream, tarfile.open(fileobj=stream, mode="r|") as libraries:
        for member in libraries:
            if not member.isfile():
                continue
            base = member.name.removesuffix(".xcframework.zip")
            with libraries.extractfile(member) as incoming, io.BytesIO(incoming.read(512 * MIB + 1)) as saved, zip_open(saved) as library:
                body = saved.getvalue()
                rows = zip_index(library)
            if base in ("Libdovi", "Libplacebo"):
                dovi_zip_bodies[base] = body
            if base in ("Libssl", "Libcrypto"):
                openssl_zip_bodies[base] = body
            if base in ("gmp", "nettle", "hogweed", "gnutls", "Libsmbclient"):
                crypto_zip_bodies[base] = body
            if base in ("Libunibreak", "Libfribidi", "Libharfbuzz", "Libbluray", "Libfreetype"):
                subtitle_zip_bodies[base] = body
            target = base if base in UNSUFFIXED_LIBRARIES else base + "-GPL"
            for name, row in rows.items():
                need(name.startswith(base + ".xcframework/"), "Apple library root")
                expected["MPVKit-DVFEL/artifacts/" + target + ".xcframework/" + name.split("/", 1)[1]] = row
    openssl_archive_binding(openssl_bom, openssl_zip_bodies)
    crypto_chain_receipt(
        read(archive, CRYPTO_CHAIN_OUTPUT, CRYPTO_MAX_RECEIPT),
        crypto_zip_bodies, archive_sources,
        candidate["MPVKit-DVFEL/Package.swift"],
        actual["MPVKit-DVFEL/Package.swift"])
    subtitle_builds_receipt(
        subtitle_bom_body, subtitle_zip_bodies, subtitle_archive_sources)
    dovi_group = next(row for row in source_groups if row['directory'] == DOVI_SOURCE_ROOT)
    dovi_builds_receipt(read(archive,DOVI_OUTPUT,DOVI_LIMIT),dovi_zip_bodies,
        read(archive,DOVI_VENDOR_OUTPUT,2*1024**3),read(archive,'native-sources-v2.tar.gz',2*1024**3),
        dovi_group,actual['MPVKit-DVFEL/Package.swift'].decode('utf-8'))
    for name, row in native.items():
        if any(name.startswith("source-0/Sources/" + value + "/") for value in ("_MPVKit", "_MPVKit-GPL", "_FFmpeg", "_FFmpeg-GPL")):
            expected["MPVKit-DVFEL/" + name.removeprefix("source-0/")] = row
    package = captured["source-0/Package.swift"].decode("utf-8")
    shaderc_remote_target(package)
    for base in LIBRARIES:
        target = base if base in UNSUFFIXED_LIBRARIES else base + "-GPL"
        pattern = r'\.binaryTarget\(\s*name:\s*"%s",\s*url:\s*"[^"]*",\s*checksum:\s*"[^"]*"\s*\)' % re.escape(target)
        replacement = '.binaryTarget(\n            name: "%s",\n            path: "artifacts/%s.xcframework"\n        )' % (target, target)
        package, count = re.subn(pattern, lambda _: replacement, package)
        need(count == 1, "Apple package source rewrite")
    need(actual.get("MPVKit-DVFEL/Package.swift") == package.encode(), "Apple package/source correspondence")
    ignore = b"# Build OUTPUT (hundreds of MB), reproducible from the pinned refs via\n# scripts/build-mpvkit-dvfel.sh. Must never enter git history.\nartifacts/\n"
    for name, data in (("Package.swift", package.encode()), (".gitignore", ignore)):
        expected["MPVKit-DVFEL/" + name] = {"bytes": len(data), "sha256": sha(data), "kind": "file", "mode": 420}
    need(candidate == expected, "Apple assembled/original ZIP/native source byte correspondence")


def package(args):
    need(re.fullmatch(r"[0-9a-f]{40}", args.source_commit) and re.fullmatch(r"[1-9][0-9]*", args.run_id) and
         re.fullmatch(r"[1-9][0-9]*", args.attempt), "Expected producer identity")
    digest(args.artifact_sha256)
    integer(args.artifact_bytes, 8 * 1024**3)
    need(args.repo.is_dir() and args.repo.resolve() == args.repo.absolute(), "Real local immutable Git repository")
    need(args.artifact_zip.is_file() and not args.artifact_zip.is_symlink(), "Original ZIP input")
    with args.artifact_zip.open("rb") as original:
        need(measure(original, 8 * 1024**3) == {"bytes": args.artifact_bytes, "sha256": args.artifact_sha256}, "Independently pinned original ZIP")
        original.seek(0)
        with zip_open(original, 256) as archive:
            inputs = zip_index(archive, count=256, total=8 * 1024**3, flat=True)
            receipt = load(read(archive, "result.json"))
            keys(receipt, "schema lane buildExit appSourceCommit workflowRef runId attempt sources runtimeSecurityTested promotionEligible")
            need(type(receipt["schema"]) is int and receipt["schema"] == 1 and type(receipt["buildExit"]) is int and receipt["buildExit"] == 0 and
                 receipt["lane"] == args.lane and receipt["appSourceCommit"] == args.source_commit and receipt["runId"] == args.run_id and receipt["attempt"] == args.attempt and
                 receipt["promotionEligible"] is False and receipt["runtimeSecurityTested"] is False and isinstance(receipt["workflowRef"], str) and
                 any(receipt["workflowRef"].startswith("VortXTV/VortX/.github/workflows/" + name + "@refs/")
                     for name in ("native-media-candidates.yml", "source-contracts.yml")), "Successful unpromoted original producer identity")
            sources = receipt["sources"]
            need(type(sources) is list and 4 <= len(sources) <= 32, "Original source group bound")
            common = {"artifact-sha256.json", "build.log", "result.json", "reviewed-inputs.sha256", "original-upstream-source.tar.gz", "toolchain.txt", "source-format-v2.json", "producer-inputs-v2.tar.gz", "native-sources-v2.tar.gz"}
            expected = common | OUTPUTS[args.lane] | {f"source-{n}.patch" for n in range(len(sources))}
            if args.lane == "android":
                expected |= {"python-toolchain.json", "ffmpeg-applied.patch", "tls_mbedtls_vortx_distrust.h"}
            manifest = load(read(archive, "artifact-sha256.json"))
            need(set(inputs) == expected and type(manifest) is dict and set(manifest) == expected - {"artifact-sha256.json", "build.log"}, "Exact original artifact membership/coverage")
            need(all(digest(value) == inputs[name]["sha256"] for name, value in manifest.items()), "Original manifest content")
            meta = load(read(archive, "source-format-v2.json"))
            keys(meta, "schema sourceProfile lane appSourceCommit runId attempt workflowRef recipeManifestSHA256 legacyReceiptSHA256 producerArchive nativeArchive producerFiles sources archiveSources subtitleArchiveSources outputs")
            need(type(meta["schema"]) is int and meta["schema"] == 2 and meta["sourceProfile"] == PROFILE and
                 all(meta[key] == receipt[key] for key in ("lane", "appSourceCommit", "runId", "attempt", "workflowRef")) and
                 meta["legacyReceiptSHA256"] == manifest["result.json"], "Exact v2 metadata identity")
            reviewed = read(archive, "reviewed-inputs.sha256", 4 * MIB)
            need(sha(reviewed) == meta["recipeManifestSHA256"] == PROFILE_MANIFEST_SHA256, "Reviewed exact profile manifest")
            recipe = {}
            for line in reviewed.decode("ascii").splitlines():
                need(re.fullmatch(r"[0-9a-f]{64}  [^ ]+", line), "Reviewed manifest row")
                checksum, name = line.split("  ")
                need(name not in recipe, "Duplicate reviewed input")
                recipe[path(name)] = checksum
            need(set(recipe) == RECIPE_PATHS and len(recipe) == 37, "Exact 37 reviewed recipe identities")
            producer = declared(meta["producerFiles"], "producer")
            need(set(producer) == {"producer/" + name for name in RECIPE_PATHS | {INPUT_MANIFEST, WORKFLOW}}, "Exact 39 producer files")
            for name, row in producer.items():
                need(row == git_blob(args.repo, args.source_commit, name.removeprefix("producer/")) and row["kind"] == "file", "Immutable producer Git blob/mode")
                relative = name.removeprefix("producer/")
                need(relative not in recipe or row["sha256"] == recipe[relative], "Reviewed producer digest")
            need(producer["producer/" + INPUT_MANIFEST]["sha256"] == sha(reviewed), "Producer input manifest bytes")
            native, groups = {}, {}
            need(type(meta["sources"]) is list and len(meta["sources"]) == len(sources), "Native group count")
            for index, (row, legacy) in enumerate(zip(meta["sources"], sources)):
                keys(legacy, "directory commit trackedDiffSHA256")
                keys(row, "receiptIndex directory commit root files gitlinks" + (" placeboSource" if "placeboSource" in row else "") + (" playerPlainSource" if "playerPlainSource" in row else ""))
                need(type(row["receiptIndex"]) is int and row["receiptIndex"] == index and row["root"] == f"source-{index}" and
                     row["directory"] == legacy["directory"] and row["commit"] == legacy["commit"] and re.fullmatch(r"[0-9a-f]{40}", row["commit"]) and
                     legacy["trackedDiffSHA256"] == manifest[f"source-{index}.patch"] and row["directory"] not in groups, "Native/legacy source identity")
                groups[row["directory"]] = row
                files = declared(row["files"], row["root"], native=True)
                created = {item["path"]: item["sha256"] for item in row["files"] if item["tracked"] is False}
                need(created == untracked(args.lane, row, recipe) and all(item["kind"] == "file" for item in row["files"] if item["tracked"] is False), "Exact recipe-created untracked file set/content")
                need(files and not set(native) & set(files), "Missing/overlapping native source group")
                native.update(files)
                need(len(row["gitlinks"]) <= 1000, "Gitlink count")
                links = validate_native_gitlinks(row, files)
                if row["commit"] == PINS["libplacebo"]:
                    need(all(links.get(name) == commit for name, commit in GITLINKS.items()), "Pinned libplacebo Gitlinks")
            known = {"libmpv-master-8c67647b": PINS["mpv"], "FFmpeg-9.0.2-946fcce0": PINS["ffmpeg"],
                     "libplacebo-7.387.0-275f7dea": PINS["libplacebo"],
                     "lcms2-2.20rc1-13154341": "1315434113566bcf3eb46c2485fcc1c0a56ab806",
                     "libdav1d-1.5.4-54706fc6": "54706fc6bc0cdecab7e9593974a4039cc038fca7",
                     OPENSSL_ROOT: OPENSSL_SOURCE_SHA, DOVI_SOURCE_ROOT: DOVI_SOURCE_COMMIT} if args.lane == "apple" else dict(ANDROID_PINS)
            known["_native-mpvkit" if args.lane == "apple" else "_native-publisher"] = WRAPPER[args.lane]
            need(set(groups) == set(known) and sources[0]["commit"] == WRAPPER[args.lane] and
                 all(groups[name]["commit"] == commit for name, commit in known.items()), "Exact admitted public native roots/revisions")
            need(len(native) <= 100000 and sum(row["bytes"] for row in native.values() if row["kind"] == "file") <= 2 * 1024**3, "Combined native bounds")
            mpv = next(row for row in meta["sources"] if row["commit"] == PINS["mpv"])
            for name, checksum in (CANCEL | READER_MPV | {"meson.build": READER_MPV_MESON[args.lane]}).items():
                row = native.get(mpv["root"] + "/" + name)
                need(row and row["kind"] == "file" and row["sha256"] == checksum, "Cancellation/finite-reader afterimage: " + name)
            ffmpeg = next(row for row in meta["sources"] if row["commit"] == PINS["ffmpeg"])
            require_response_source({row["path"]: row for row in ffmpeg["files"]}, args.lane)
            expected_archive_sources = crypto_source_outputs(archive) if args.lane == "apple" else None
            need(exact_equal(meta["archiveSources"], expected_archive_sources),
                 "Archive-backed source metadata/raw-body/capture correspondence")
            expected_subtitle_archive_sources = (subtitle_source_outputs(archive)
                                                 if args.lane == "apple" else None)
            need(exact_equal(meta["subtitleArchiveSources"],
                             expected_subtitle_archive_sources),
                 "Subtitle archive-backed source metadata/raw-body/capture correspondence")
            for key, name, expected_rows in (("producerArchive", "producer-inputs-v2.tar.gz", producer), ("nativeArchive", "native-sources-v2.tar.gz", native)):
                keys(meta[key], "name sha256 bytes")
                need(meta[key] == dict(name=name, sha256=inputs[name]["sha256"], bytes=inputs[name]["bytes"]), "V2 archive identity")
                actual, captured = tar_index(archive, name, capture=("source-0/Package.swift", "source-0/Sources/BuildScripts/XCFrameworkBuild/main.swift"))
                need(actual == expected_rows, "Complete tar/inventory byte/mode correspondence")
            for group in meta["sources"]:
                if "placeboSource" in group:
                    need(args.lane == "apple", "LP virtual provider route is Apple-only")
                    libplacebo_virtual_raw_sources(archive, group, captured)
                if "playerPlainSource" in group:
                    need(args.lane == "apple" and "placeboSource" not in group, "full player plain route is Apple-only and distinct from LP")
                    _pp_inventory(group['files'], group['playerPlainSource'], untracked(args.lane, group, recipe))
                    player_plain_raw_sources(archive, group, captured)
            need(type(meta["outputs"]) is list and len(meta["outputs"]) == len(OUTPUTS[args.lane]), "Output count")
            bound = {}
            for row in meta["outputs"]:
                keys(row, "name sha256 bytes")
                need(row["name"] in OUTPUTS[args.lane] and row["name"] not in bound and row == dict(name=row["name"], sha256=inputs[row["name"]]["sha256"], bytes=inputs[row["name"]]["bytes"]), "Same-byte lane output binding")
                bound[row["name"]] = row
            android(archive, inputs, recipe) if args.lane == "android" else apple(
                archive, native, captured, recipe, expected_archive_sources,
                expected_subtitle_archive_sources, meta["sources"])
            out = args.out.absolute()
            need(out.parent.is_dir() and out.parent.resolve() == out.parent and not out.exists() and not out.is_symlink(), "Fresh real output parent")
            out.mkdir(mode=0o700, exist_ok=False)
            binary = "apple-candidate.tar.gz" if args.lane == "apple" else "libmpv-release-candidate.aar"
            outputs, content = {}, {}
            original.seek(0)
            with (out / "original-ci.zip").open("xb") as sink:
                outputs["original-ci.zip"] = measure(original, 8 * 1024**3, sink)
            need(outputs["original-ci.zip"] == {"bytes": args.artifact_bytes, "sha256": args.artifact_sha256}, "Original ZIP copy changed")
            with archive.open(binary) as stream, (out / binary).open("xb") as sink:
                outputs[binary] = measure(stream, 4 * 1024**3, sink)
            need(outputs[binary] == {key: inputs[binary][key] for key in ("bytes", "sha256")}, "Binary copy changed")
            tool = Path(__file__).read_bytes()
            with GIT.open("rb") as stream:
                git_tool = measure(stream, 64 * MIB)
            excluded = {"apple-original-library-zips.tar"} if args.lane == "apple" else set()
            with (out / "candidate-source-kit.tar.gz").open("xb") as raw, gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0, compresslevel=1) as compressed, tarfile.open(fileobj=compressed, mode="w|") as target:
                for name in sorted(set(inputs) - {binary} - excluded):
                    member = tarfile.TarInfo("original-evidence/" + name)
                    member.size, member.mode, member.mtime = inputs[name]["bytes"], 0o644, 0
                    with archive.open(name) as stream:
                        target.addfile(member, stream)
                    content[member.name] = {key: inputs[name][key] for key in ("bytes", "sha256")}
                member = tarfile.TarInfo("packaging/package-native-current-component.py")
                member.size, member.mode, member.mtime = len(tool), 0o644, 0
                target.addfile(member, io.BytesIO(tool))
                content[member.name] = {"bytes": len(tool), "sha256": sha(tool)}
            with tarfile.open(out / "candidate-source-kit.tar.gz", "r|gz") as saved:
                seen = set()
                for member in saved:
                    need(member.name in content and member.name not in seen and member.isfile() and
                         member.mode == 0o644 and member.size == content[member.name]["bytes"], "Source-kit readback membership/mode")
                    seen.add(member.name)
                    with saved.extractfile(member) as stream:
                        need(measure(stream, 4 * 1024**3) == content[member.name], "Source-kit readback bytes")
                need(seen == set(content), "Source-kit readback coverage")
            with (out / "candidate-source-kit.tar.gz").open("rb") as stream:
                outputs["candidate-source-kit.tar.gz"] = measure(stream, 8 * 1024**3)
            provenance = {"schema": 1, "sourceProfile": PROFILE, "producer": receipt, "inputFiles": inputs,
                          "originalZIP": outputs["original-ci.zip"], "toolSHA256": sha(tool), "gitEntrypoint": git_tool, "sourceKitContent": content,
                          "sourceKitExcludedBinaryCarriers": {name: {key: inputs[name][key] for key in ("bytes", "sha256")} for name in sorted(excluded)},
                          "outputs": outputs, "nativeRebuilt": False, "independentBinaryInspection": False,
                          "sourceCaptureScope": ("seven strict Git roots plus seven independently reindexed archive-backed crypto and subtitle/bluray release roots"
                                                 if args.lane == "apple" else
                                                 "cached/nonignored native files and recursive Gitlinks; Android original full deps/config archives also retained"),
                          "archiveSourceRootCount": 7 if args.lane == "apple" else 0,
                          "unresolvedExternalSourceObligations": True,
                          "externalCIauthenticationRequired": True,
                          "originalCIReclassified": False,
                          "runtimeSecurityTested": False, "publicationApproved": False, "promotionEligible": False}
            encoded = (json.dumps(provenance, indent=2, sort_keys=True) + "\n").encode()
            with (out / "packaging-provenance.json").open("xb") as sink:
                sink.write(encoded)
            outputs["packaging-provenance.json"] = {"bytes": len(encoded), "sha256": sha(encoded)}
            with (out / "SHA256SUMS").open("x") as sink:
                sink.write("".join(row["sha256"] + "  " + name + "\n" for name, row in sorted(outputs.items())))
            need({p.name for p in out.iterdir()} == set(outputs) | {"SHA256SUMS"}, "Output membership")
    print(json.dumps({"status": "unpromoted-candidate-packaged", "lane": args.lane, "promotionEligible": False}))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("artifact-zip", "repo", "out"):
        parser.add_argument("--" + name, type=Path, required=True)
    for name in ("artifact-sha256", "run-id", "attempt", "source-commit"):
        parser.add_argument("--" + name, required=True)
    parser.add_argument("--artifact-bytes", type=int, required=True)
    parser.add_argument("--lane", choices=sorted(OUTPUTS), required=True)
    package(parser.parse_args())
