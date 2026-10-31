#!/usr/bin/env python3
"""Candidate evidence only. No publication, device execution or runtime-security verdict."""
import base64
import binascii
import gzip
import hashlib
import io
import json
import lzma
import os
from pathlib import Path
import posixpath
import re
import shlex
import shutil
import stat
import subprocess
import sys
import tarfile
import struct
import tomllib
import tempfile
import zipfile
import unicodedata


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def run(*args):
    return subprocess.check_output(args, text=True, timeout=60)


def save(path, data):
    path.write_text(json.dumps(data, indent=2, sort_keys=True) + '\n')


# The dependency-upgrade receipt is deliberately separate from the existing
# shipping/source profile.  The coordinator seals the profile and manifest
# literals after rebasing this recovery-only delta onto the next carrier.
NATIVE_UPGRADES_PROFILE = 'native-upgrades-openssl410-crypto-subtitles-bluray150-freetype2150-libdovi340-v7'
SHADERC_WRAPPER_VERSION = '2026.1.0'
SHADERC_SOURCE_SPECS = (
    ('libshaderc.zip', 124322785,
     'd213fa58de7886846fb8cb713ea5213b77654a3ad2ba3d89b1f2fe367d945ba5'),
    ('Libshaderc_combined.xcframework.zip', 61246203,
     '77a3d355993cf53843a394bf58262dab99cdd93f9e6fe31d5ca6e55b03866ce1'),
)
SHADERC_MATRIX = (
    ('ios-arm64', 'arm64', 'ios'),
    ('ios-arm64_x86_64-simulator', 'arm64', 'isimulator'),
    ('ios-arm64_x86_64-simulator', 'x86_64', 'isimulator'),
    ('tvos-arm64_arm64e', 'arm64', 'tvos'),
    ('tvos-arm64_arm64e', 'arm64e', 'tvos'),
    ('tvos-arm64_x86_64-simulator', 'arm64', 'tvsimulator'),
    ('tvos-arm64_x86_64-simulator', 'x86_64', 'tvsimulator'),
    ('macos-arm64_x86_64', 'arm64', 'macos'),
    ('macos-arm64_x86_64', 'x86_64', 'macos'),
)
SHADERC_MAX_ENTRIES = 100000
SHADERC_MAX_MEMBER = 512 * 1024**2
SHADERC_MAX_TOTAL = 4 * 1024**3
SHADERC_MAX_LINK_BODY = 4096
SHADERC_MAX_LINK_HOPS = 8
SHADERC_XC_MAC_FRAMEWORK = (
    'Libshaderc_combined.xcframework/macos-arm64_x86_64/'
    'Libshaderc_combined.framework')
SHADERC_XC_LINKS = {
    SHADERC_XC_MAC_FRAMEWORK + '/Resources': 'Versions/Current/Resources',
    SHADERC_XC_MAC_FRAMEWORK + '/Libshaderc_combined':
        'Versions/Current/Libshaderc_combined',
    SHADERC_XC_MAC_FRAMEWORK + '/Versions/Current': 'A',
}

OPENSSL_BOM_PROFILE = 'openssl-4.1.0-source-v1'
OPENSSL_SOURCE = {
    'repository': 'https://github.com/openssl/openssl',
    'tag': 'openssl-4.1.0',
    'commit': '2f4e3a5fec05394068cfa7379890ab552483a8a6',
    'version': '4.1.0',
}
OPENSSL_GITLINKS = {
    'cloudflare-quiche': '7ab6a55cfe471267d61e4d28ba43d41defcd87e0',
    'gost-engine': '74b1f4fddbc2d6de969815b1992ddc1ae7c643fe',
    'krb5': '784c38f50e70a739400cdd3f2620bac2e2788e6c',
    'oqs-provider': 'c5fb439e4ffd947f24c139232fb04fd71fe3c29e',
    'pkcs11-provider': 'eb157e48066fdb2b5735f6f327ed7ae65c51eb6f',
    'pyca-cryptography': 'e83bbe58e373536636baaa7c33a64a6e8f04c953',
    'python-ecdsa': '4096fa01715929e08b97e73f3173aee9d57f2a3f',
    'fuzz/corpora': '7e3fb43a75c55275759e8bdb5c32de4b50978eab',
    'tlsfuzzer': '61f45d9701294fd87ef92d2a7e3dfb076653a562',
    'tlslite-ng': '77ef321dde1a9e6bcf94d73c80f8789a770d8031',
    'wycheproof': '3fa63dd0344abb611f1fb1d77e119938603ea230',
}
OPENSSL_ROOT = 'openssl-4.1.0-2f4e3a5f'
OPENSSL_OUTPUT_ROOT = 'openssl'
OPENSSL_CONFIGURE_FLAGS = ('no-async', 'no-shared', 'no-dso', 'no-tests', 'no-apps', 'no-docs')
OPENSSL_PKG_LIBRARIES = ('libmpv', 'FFmpeg', 'libshaderc', 'vulkan', 'lcms2', 'libdovi',
                         'openssl', 'libunibreak', 'libfreetype', 'libfribidi', 'libharfbuzz',
                         'libass', 'libsmbclient', 'libplacebo', 'libdav1d', 'gmp', 'nettle',
                         'gnutls', 'libuchardet', 'libbluray', 'libluajit', 'libuavs3d')
OPENSSL_COMPLETED_STEPS = ('Configure', 'make build_sw', 'make install_sw')
OPENSSL_ENV_KEYS = ('CC', 'CXX', 'CFLAGS', 'CPPFLAGS', 'CXXFLAGS', 'ASMFLAGS',
                    'LDFLAGS', 'PKG_CONFIG_LIBDIR', 'PKG_CONFIG_PATH', 'PATH',
                    'CURRENT_ARCH', 'LC_CTYPE', 'AR', 'ARFLAGS', 'RANLIB',
                    'MAKEFLAGS', 'CMAKE_BUILD_PARALLEL_LEVEL', 'CARGO_BUILD_JOBS')
OPENSSL_EFFECTIVE_KEYS = ('target', 'CC', 'CFLAGS', 'CPPFLAGS', 'CXX', 'CXXFLAGS',
                           'LDFLAGS', 'AR', 'ARFLAGS', 'RANLIB', 'CROSS_COMPILE',
                           'cflags', 'cppflags', 'lflags', 'lib_cppflags')
OPENSSL_DEFAULT_PATH = '/Library/Frameworks/Python.framework/Versions/Current/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin'
OPENSSL_OUTPUTS = (
    ('libssl.a', 'lib/libssl.a', 512 * 1024**2),
    ('libcrypto.a', 'lib/libcrypto.a', 512 * 1024**2),
    ('opensslv.h', 'include/openssl/opensslv.h', 1024 * 1024),
)
OPENSSL_MATRIX = (
    ('ios', 'arm64', 'vortx-apple-ios-arm64', 'ios-arm64'),
    ('isimulator', 'arm64', 'vortx-apple-isimulator-arm64', 'ios-arm64_x86_64-simulator'),
    ('isimulator', 'x86_64', 'vortx-apple-isimulator-x86_64', 'ios-arm64_x86_64-simulator'),
    ('tvos', 'arm64', 'vortx-apple-tvos-arm64', 'tvos-arm64_arm64e'),
    ('tvos', 'arm64e', 'vortx-apple-tvos-arm64e', 'tvos-arm64_arm64e'),
    ('tvsimulator', 'arm64', 'vortx-apple-tvsimulator-arm64', 'tvos-arm64_x86_64-simulator'),
    ('tvsimulator', 'x86_64', 'vortx-apple-tvsimulator-x86_64', 'tvos-arm64_x86_64-simulator'),
    ('macos', 'arm64', 'vortx-apple-macos-arm64', 'macos-arm64_x86_64'),
    ('macos', 'x86_64', 'vortx-apple-macos-x86_64', 'macos-arm64_x86_64'),
)
OPENSSL_MAX_RECEIPT = 4 * 1024 * 1024
OPENSSL_MAX_TARGET_CONFIG = 1024 * 1024

CRYPTO_SOURCE_PROFILE = 'gmp630-nettle400-gnutls3813-release-sources-v1'
CRYPTO_CHAIN_PROFILE = 'native-upgrades-crypto-chain-v1'
CRYPTO_CHAIN_OUTPUT = 'apple-crypto-chain.json'
CRYPTO_SOURCE_OUTPUTS = (
    {
        'id': 'gmp', 'version': '6.3.0', 'archiveRoot': 'gmp-6.3.0',
        'filename': 'gmp-6.3.0.tar.xz', 'compression': 'xz', 'bytes': 2094196,
        'sha256': 'a3c2b80201b89e68616f4ad30bc66aee4927c3ce50e33929ca819d5c43538898',
        'sourceRoot': 'gmp-6.3.0-a3c2b802',
        'url': 'https://ftp.gnu.org/gnu/gmp/gmp-6.3.0.tar.xz',
        'output': 'apple-crypto-source-gmp.tar.xz',
    },
    {
        'id': 'nettle', 'version': '4.0', 'archiveRoot': 'nettle-4.0',
        'filename': 'nettle-4.0.tar.gz', 'compression': 'gz', 'bytes': None,
        'sha256': '3addbc00da01846b232fb3bc453538ea5468da43033f21bb345cb1e9073f5094',
        'sourceRoot': 'nettle-4.0-3addbc00',
        'url': 'https://ftp.gnu.org/gnu/nettle/nettle-4.0.tar.gz',
        'output': 'apple-crypto-source-nettle.tar.gz',
    },
    {
        'id': 'gnutls', 'version': '3.8.13', 'archiveRoot': 'gnutls-3.8.13',
        'filename': 'gnutls-3.8.13.tar.xz', 'compression': 'xz', 'bytes': 7275324,
        'sha256': 'ffed8ec1bf09c2426d4f14aae377de4753b53e537d685e604e99a8b16ca9c97e',
        'sourceRoot': 'gnutls-3.8.13-ffed8ec1',
        'url': 'https://www.gnupg.org/ftp/gcrypt/gnutls/v3.8/gnutls-3.8.13.tar.xz',
        'output': 'apple-crypto-source-gnutls.tar.xz',
    },
)
CRYPTO_CAPTURE_TAR_OUTPUT = 'apple-crypto-release-sources.tar'
CRYPTO_CAPTURE_RECEIPT_OUTPUT = 'apple-crypto-release-sources.json'
CRYPTO_MAX_ARCHIVE = 8 * 1024 * 1024
CRYPTO_MAX_UNCOMPRESSED = 512 * 1024 * 1024
CRYPTO_MAX_MEMBERS = 100000
CRYPTO_MAX_MEMBER = 64 * 1024 * 1024
CRYPTO_MAX_RECEIPT = 64 * 1024 * 1024
CRYPTO_MAX_PATH = 4096
CRYPTO_MAX_MTIME = 4102444800
CRYPTO_MAX_MTIME_NS = CRYPTO_MAX_MTIME * 1000000000
CRYPTO_INSTALLED_HELPERS = {
    'Sources/BuildScripts/crypto-release-sources.py':
        '3c310499d446eed72eb16521b27c16f718f23e7ab1472dec1fad79cc40ed1537',
    'Sources/BuildScripts/crypto-chain-gate.py':
        '69a180d417c8295d723ec3eb904d93414d668e55e15d9902f93718bdcfbe0485',
}

SUBTITLE_SOURCE_PROFILE = 'unibreak800-fribidi1017-harfbuzz1500-bluray150-freetype2150-release-sources-v4-pax-ns'
SUBTITLE_SOURCE_OUTPUTS = (
    {
        'id': 'libunibreak', 'version': '8.0', 'archiveRoot': 'libunibreak-8.0',
        'filename': 'libunibreak-8.0.tar.gz', 'compression': 'gz', 'bytes': None,
        'maximumBytes': 8 * 1024 * 1024, 'entryPoint': 'configure',
        'sha256': '9c4fad6e517338a098373acc9f35579ae2c325e6446666fb9ac2666ba15ceba4',
        'sourceRoot': 'libunibreak-8.0-9c4fad6e',
        'url': ('https://github.com/adah1972/libunibreak/releases/download/'
                'libunibreak_8_0/libunibreak-8.0.tar.gz'),
        'output': 'apple-subtitle-source-unibreak.tar.gz',
    },
    {
        'id': 'libfribidi', 'version': '1.0.17', 'archiveRoot': 'fribidi-1.0.17',
        'filename': 'fribidi-1.0.17.tar.xz', 'compression': 'xz', 'bytes': 1203284,
        'maximumBytes': 8 * 1024 * 1024, 'entryPoint': 'meson.build',
        'sha256': '6949dcde27d41cebad1fd741fcafc36d55a1020d2d872d4a6eb3914caabbada2',
        'sourceRoot': 'libfribidi-1.0.17-6949dcde',
        'url': 'https://github.com/fribidi/fribidi/releases/download/v1.0.17/fribidi-1.0.17.tar.xz',
        'output': 'apple-subtitle-source-fribidi.tar.xz',
    },
    {
        'id': 'libharfbuzz', 'version': '15.0.0', 'archiveRoot': 'harfbuzz-15.0.0',
        'filename': 'harfbuzz-15.0.0.tar.xz', 'compression': 'xz', 'bytes': 20396372,
        'maximumBytes': 32 * 1024 * 1024, 'entryPoint': 'meson.build',
        'sha256': '968536e9abd782f07f7954044c0c4020199fcdd39b41d221ec42d2a3be4a44df',
        'sourceRoot': 'libharfbuzz-15.0.0-968536e9',
        'url': 'https://github.com/harfbuzz/harfbuzz/releases/download/15.0.0/harfbuzz-15.0.0.tar.xz',
        'output': 'apple-subtitle-source-harfbuzz.tar.xz',
    },
    {
        'id': 'libbluray', 'version': '1.5.0', 'archiveRoot': 'libbluray-1.5.0',
        'filename': 'libbluray-1.5.0.tar.xz', 'compression': 'xz', 'bytes': 473072,
        'maximumBytes': 473072, 'entryPoint': 'meson.build',
        'sha256': 'f676408e91a5d321abf8b8d4dfdae36205c297dab5c54c3ec519639025f474a2',
        'sourceRoot': 'libbluray-1.5.0-f676408e',
        'url': 'https://download.videolan.org/pub/videolan/libbluray/1.5.0/libbluray-1.5.0.tar.xz',
        'sourceTransformPolicy': 'bluray150-retained-apple-mobile-v1',
        'output': 'apple-bluray-source.tar.xz',
    },
)
SUBTITLE_SOURCE_OUTPUTS = SUBTITLE_SOURCE_OUTPUTS + ({'id': 'libfreetype', 'version': '2.15.0', 'archiveRoot': 'freetype-37515cf56ba3349656049edbed89ffc6f6466f2d', 'filename': 'freetype-37515cf56ba3349656049edbed89ffc6f6466f2d.tar.gz', 'compression': 'gz', 'bytes': 2594500, 'maximumBytes': 2594500, 'entryPoint': 'meson.build', 'sha256': '9efee8b0508e142f38d1c7e2e192d3e5041aa4bbf6c2ab1a901518211f76a914', 'sourceRoot': 'libfreetype-2.15.0-37515cf5', 'url': 'https://gitlab.freedesktop.org/freetype/freetype/-/archive/37515cf56ba3349656049edbed89ffc6f6466f2d/freetype-37515cf56ba3349656049edbed89ffc6f6466f2d.tar.gz', 'sourceTransformPolicy': 'freetype2150-git-membership-empty-dlg-v1', 'output': 'apple-freetype-source.tar.gz'},)

# Official immutable FreeType 2.15.0 Git membership, retained without decoding a source archive.
FREETYPE_SOURCE_COMMIT = '37515cf56ba3349656049edbed89ffc6f6466f2d'
FREETYPE_SOURCE_TREE = '9ae032bd6c9a81300af54b4c9d92b975e1404a5c'
FREETYPE_EMPTY_GITLINKS = {"subprojects/dlg": "395ccad2c1e0daae535c4d20bb0a3f2424648e17"}
FREETYPE_GIT_FILES = {'.clang-format': (420, 'fbd04c11cbf2056a445add4914d0e5693c67b82f'), '.gitignore': (420, 'e4f1510bf9fa53e42ff14b918c79c185c4dba38a'), '.gitlab-ci.yml': (420, '9dc33ae213ed3a501025e9e350b50852716232ca'), '.gitmodules': (420, 'b452dffb93b18b41c75a50de9c08e4b07962ee6e'), '.mailmap': (420, '31d2a47663c122720e4cbad12b5ef874080b1d53'), 'CMakeLists.txt': (420, 'fc8bcc8af939279f0f303ed2989419af12967c10'), 'LICENSE.TXT': (420, '0f9df2177a47a3e463e45d295afdcc783766836e'), 'MSBuild.rsp': (420, '8401e60309f18cf8e4007c99e6b208fd497e8833'), 'MSBuild.sln': (420, 'ba56ae2ef89cdc090d39a6ea4b62d68daecccd37'), 'Makefile': (420, '03c0429837c77cff9a8092991547ae63448af97b'), 'README': (420, '94b8fc7bb13b9e8666dbaf199226d1a6c8883135'), 'README.git': (420, '16cf434dbf970d1830d0d9fd1881527172b092fc'), 'autogen.sh': (493, 'e6f1ebf234af119332b9850b5dda0d78af796f7f'), 'builds/amiga/README': (420, 'afb06c370809cd161b2c01b1fae9e757779265a8'), 'builds/amiga/include/config/ftconfig.h': (420, '90ad5c853ab46f134704fb72bc7c8dc0a228f44f'), 'builds/amiga/include/config/ftmodule.h': (420, '9f76b17a01b3194abba0d61554eb96cc866658b3'), 'builds/amiga/makefile': (420, '8b5a5c0b99a431f9f7b4c426813521c68ecaf996'), 'builds/amiga/makefile.os4': (420, '88fe16f19554092f1005f49ee61cee17d1597c9f'), 'builds/amiga/smakefile': (420, '5edf4bec042367704f18ecab9834b97fa8d7b891'), 'builds/amiga/src/base/ftdebug.c': (420, 'a458bbad1a503a6bf86a1c61046841701b720e53'), 'builds/amiga/src/base/ftsystem.c': (420, '201ef0bde3bb01b049de86e7779a90fd7e1b8742'), 'builds/ansi/ansi-def.mk': (420, '7b4564a667320d6e0e37bb0515d7ea705412c4a5'), 'builds/ansi/ansi.mk': (420, '31a60469d811c9e863507a41dbfea48ebb18ca03'), 'builds/atari/ATARI.H': (420, '4ddd2eb2ebaa1a97a461a1d821677acc6196b045'), 'builds/atari/FNames.SIC': (420, 'f3657179d919530820462ad3ade981da4b356349'), 'builds/atari/FREETYPE.PRJ': (420, '4776a5bc690aadd82efb537fa4ce8eb349845a43'), 'builds/atari/README.TXT': (420, '1300817b2617f1b1f0c6ea4349d94d32dc6c84ea'), 'builds/atari/deflinejoiner.awk': (420, '16d9e6dd9333e05e73a5b2b699c72ab7966d11a9'), 'builds/atari/gen-purec-patch.sh': (493, '1ec050c11fa3cbbba26c610dfa32787f5a995795'), 'builds/beos/beos-def.mk': (420, '55e61eb88cdb61137824eef72e0179805366494b'), 'builds/beos/beos.mk': (420, '7579b187d7cef1ab9c909566b1239f38169cd3fb'), 'builds/beos/detect.mk': (420, 'a045e5ffe0a60b6fc05c2f922228a046c391bfee'), 'builds/cmake/FindBrotliDec.cmake': (420, '97efb8867c09365d4b8f83f91952ae92d89156ae'), 'builds/cmake/FindHarfBuzz.cmake': (420, '0f0e33a1a1feb654f78473d48416315e16f896cb'), 'builds/cmake/iOS.cmake': (420, '8f82d61d34bfb0a69bb64a30a5df8a0a02744ae8'), 'builds/cmake/testbuild.sh': (493, '6d1661386bf6363ac043c39ff00b40d93e63cc31'), 'builds/compiler/ansi-cc.mk': (420, '9fd5b0eb2aa58e697041f6ef5307795bc3a686ab'), 'builds/compiler/bcc-dev.mk': (420, 'f03d16c7799a2a6bca6e95044c8bf92099ad3b1c'), 'builds/compiler/bcc.mk': (420, '24d56e0267703cd770a14c214c268bed1bff5f22'), 'builds/compiler/emx.mk': (420, 'e5c3fdc70dbc73a8269fe0ea788cdad6c7215f4c'), 'builds/compiler/gcc-dev.mk': (420, '691bceb29ed972aa26b9d9c3f219c8e6093f3833'), 'builds/compiler/gcc.mk': (420, 'ab8c55ffabfe2cf10edf5e87ed3a572e0c7bc2fc'), 'builds/compiler/intelc.mk': (420, '1fd53c2d88eb6abceab3eec875c017be6e990e51'), 'builds/compiler/unix-lcc.mk': (420, 'b8b1fbc063ed2388aa15b7a2bb4c8523e010b4d4'), 'builds/compiler/visualage.mk': (420, '8c1dcdb65c9be8f5c1689c5ff8085e33c2de4972'), 'builds/compiler/visualc.mk': (420, '4754c0e97c812363cdecc94776f8d4e6e56b6c2e'), 'builds/compiler/watcom.mk': (420, 'd6d24a49f1c3ac3f252c7d4941f24c7588b3980e'), 'builds/compiler/win-lcc.mk': (420, '06b1644a66534cebbd491d10dd04046102666745'), 'builds/detect.mk': (420, '7c5b97389b1309963211e3f7418155d77e735e27'), 'builds/dos/detect.mk': (420, '1d181240aa92f9bd62e336b7284d43fc98e62588'), 'builds/dos/dos-def.mk': (420, '88f70167fcdd895dfaadfa4979515d302b2136d7'), 'builds/dos/dos-emx.mk': (420, 'f1bc35954cc3f577d9fab04b014b3f2b6545c717'), 'builds/dos/dos-gcc.mk': (420, 'f7bc5551e3a459d7524224cf4f637bce782ee080'), 'builds/dos/dos-wat.mk': (420, '6e096e6493502352ec31ad386edcc326a230d7b4'), 'builds/exports.mk': (420, '1df4010d28d9021adf932b642bc305aba427c4a8'), 'builds/freetype.mk': (420, 'b6ff865b74710df92c5e2fff2b7c3d35c16ee896'), 'builds/link_dos.mk': (420, '923639d489d83816f9e4a3cff881e5fd35117a59'), 'builds/link_std.mk': (420, '008de5170c81a79181d771d1585f6a3fec6a4caf'), 'builds/mac/FreeType.m68k_cfm.make.txt': (420, 'b74565f10796908a89d67644a5405f4cbe6856e9'), 'builds/mac/FreeType.m68k_far.make.txt': (420, 'd880ddbb7c6c54749f8862d0f815575f455a7ef7'), 'builds/mac/FreeType.ppc_carbon.make.txt': (420, '1fa8c307608e7d8f96b598db3c171cea7f2a132a'), 'builds/mac/FreeType.ppc_classic.make.txt': (420, '2550190cbf4ad90ebca1799b541e1038a0c25a66'), 'builds/mac/README': (420, '06e3d51da86ae6f5aab2eeccd8c40866a6f22218'), 'builds/mac/ascii2mpw.py': (493, 'ad32b219772550f2efecb6029ace370cce08aa0c'), 'builds/mac/freetype-Info.plist': (420, '344e5ac0b3a683edefc7191ac79dca1c5208b623'), 'builds/mac/ftlib.prj.xml': (420, 'cbbc45ee55c5c18fe936f5ce3c1fe6fa5970e101'), 'builds/mac/ftmac.c': (420, '77eb874389dd952d7515cf0c4617bcb0f3ffce41'), 'builds/meson/extract_freetype_version.py': (420, '23889620390892d50b09f6f370026e7f34324cd5'), 'builds/meson/extract_libtool_version.py': (420, '4ffdb1a0b61110983b768b624d80397364f7005b'), 'builds/meson/generate_reference_docs.py': (420, '3022e0758c7288b23ab647ca2055d477e840a9e6'), 'builds/meson/parse_modules_cfg.py': (420, '40d30323ba9cbe6d7bc0cb0ebe980af19edbc35d'), 'builds/meson/process_ftoption_h.py': (420, 'd5a217268f7de613a39be8687a0747d3d9cabc4d'), 'builds/modules.mk': (420, 'bcc61f09f9a093bddb7b2af8aa0bc207cbe9ed98'), 'builds/os2/detect.mk': (420, 'dfd15344561572639100e14651ed47287fb87f64'), 'builds/os2/os2-def.mk': (420, '8f7b7d49d941c491c6d697fee722f03fe1a79b93'), 'builds/os2/os2-dev.mk': (420, 'de5d4c906770f0425df2dd3183e4f246946c88be'), 'builds/os2/os2-gcc.mk': (420, 'db681adbfe25ea9fd45af824dd348f700135a8c4'), 'builds/plan9/README': (420, '344750d866d5a5f1f612589f862e4cab033b2371'), 'builds/plan9/p9lib.h': (420, '187e2a1c0b9bdc73164555dd1bd49ec520d1fae9'), 'builds/symbian/bld.inf': (420, '2f28097e4c4401a4ce1c75e488938c803852a89f'), 'builds/symbian/freetype.mmp': (420, '03490acada538c3b006c0d29f4be51f3392f16f9'), 'builds/toplevel.mk': (420, 'aaace59206a201e042b4284abbadb1079f68f560'), 'builds/unix/.gitignore': (420, 'f89b226b81a99c2602b5ba08fc69b0121b93a02e'), 'builds/unix/ax_compare_version.m4': (420, 'ffb4997e8b146e1e40f5da58fee4f4150290f4a4'), 'builds/unix/ax_prog_python_version.m4': (420, 'dbc3dbf1da69eb1bd164b4992bc17c5b3ae3820a'), 'builds/unix/ax_pthread.m4': (420, 'e5858e50c3c45d2444fbd252df5c24496d96d6f1'), 'builds/unix/configure.raw': (420, '9e585c7114a5742f4397bf47357ac20aa61a8153'), 'builds/unix/detect.mk': (420, '2facdf7581c0bd704de7eb5d2fb7032a0a845683'), 'builds/unix/freetype-config.in': (420, '4e69a06725cdac205f5a968e0cc1c8d2f2f6a76a'), 'builds/unix/freetype2.in': (420, 'fe389f4b6fef51f82dc7b938c02e136dbc84318d'), 'builds/unix/freetype2.m4': (420, 'c08ef9eac870c7b8ad30805c91504573dcc2adef'), 'builds/unix/ft-munmap.m4': (420, 'f4df34c5b75a2a49f51841de0576cf9f991e67c6'), 'builds/unix/ftconfig.h.in': (420, '1fc1e28fb5283f38d7c37811c819bfb1e01e6d3c'), 'builds/unix/ftsystem.c': (420, '7575da328b89ee9328991c0945185b587a5a2535'), 'builds/unix/install.mk': (420, '1bfdd1daca7c69b61735e2d89cb107a7bcaf065e'), 'builds/unix/pkg.m4': (420, '260e1fb9221c08bff990281913a81d0389d8c350'), 'builds/unix/unix-cc.in': (420, '15767cb29898f8692833e242585cdae9bff6719b'), 'builds/unix/unix-def.in': (420, '9bf2e2b57235b81e38bfb4a8eb5199f24f0efe2b'), 'builds/unix/unix-dev.mk': (420, '347c922f6af6cf6be9324e512c2f73027e4a5b8a'), 'builds/unix/unix-lcc.mk': (420, 'c0c1978c88eee0946bf4f359e9337a77f2a8947f'), 'builds/unix/unix.mk': (420, '97b29473bcf936b304ef8827316b12a3e9f9af62'), 'builds/unix/unixddef.mk': (420, '223593bae73a03d8309efe084f573ed97cf8084e'), 'builds/vms/apinames_vms.bash': (420, '1928d21ae7376184ccc45d20897ccea4da153ca8'), 'builds/vms/ftconfig.h': (420, 'da4799e3aa63756542538571db1f85b1c0c4ef47'), 'builds/vms/ftsystem.c': (420, 'e325e9c6ed785de85bc4d0b6c8c6b3d0644f8147'), 'builds/vms/patch_ftcalc.sed': (420, '79174183e48986b4c175bab15cc27f1a7283d562'), 'builds/wince/ftdebug.c': (420, '221d7c882e872dad8aa7603ff448c078f8d146b2'), 'builds/wince/vc2005-ce/freetype.sln': (420, '62c6a657bc0112a1e4a5dd736256239389ae4b85'), 'builds/wince/vc2005-ce/freetype.vcproj': (420, 'efdb587021ca03a2d5b2121e3590d4888dbd5c3a'), 'builds/wince/vc2005-ce/index.html': (420, '297ddebf656ed68d21f7d42955838dfcd444fccd'), 'builds/wince/vc2008-ce/freetype.sln': (420, '23914323c9cf194b8a923219cd66059440cb898a'), 'builds/wince/vc2008-ce/freetype.vcproj': (420, 'd01c5b59f13bfac194c0dd973152d19efeeb02b8'), 'builds/wince/vc2008-ce/index.html': (420, '5f21af5ee840db9e90b8c3fa65abe68970d20c58'), 'builds/windows/.gitignore': (420, '41456a48a13bb13f9831f169d6c29c56f74e31f9'), 'builds/windows/detect.mk': (420, '6ca3ca1ac58b37e4db06805bf39bde5e4fe975ab'), 'builds/windows/ftdebug.c': (420, '96bb0688a1b90a37e87533aad5f438083b20fd43'), 'builds/windows/ftsystem.c': (420, '3d20566a72ba6b69633659bfd4e4dae0984ada6a'), 'builds/windows/vc2010/freetype.user.props': (420, '234dd5d7959d01d731fa769d35fa46278b4bd6f4'), 'builds/windows/vc2010/freetype.vcxproj': (420, '4efd9d460ed6ae681715739186051804c8585533'), 'builds/windows/vc2010/freetype.vcxproj.filters': (420, '4085f6c4d9b9c2106af39bcaa535126febd5801c'), 'builds/windows/vc2010/index.html': (420, 'd26745b9ec902b61f84c987f46b771264aee97f8'), 'builds/windows/visualc/freetype.dsp': (420, '540f5b9adee1224ecf551b83546765b61cbba5c2'), 'builds/windows/visualc/freetype.dsw': (420, 'b149e769b5a7a40d9761039b962befded439af22'), 'builds/windows/visualc/freetype.sln': (420, '9054d0abe03ff94d8af5e8edd065564eb9b8ffa3'), 'builds/windows/visualc/freetype.vcproj': (420, '6a5b9d697d8e69361b688a7e6197d02c7fc7f41d'), 'builds/windows/visualc/index.html': (420, '1267573c12615471518f1984b8bb63b64281d178'), 'builds/windows/visualce/freetype.dsp': (420, '714c422574383f357ed32fd4fb8f8836ac861dc1'), 'builds/windows/visualce/freetype.dsw': (420, 'b149e769b5a7a40d9761039b962befded439af22'), 'builds/windows/visualce/freetype.vcproj': (420, 'c4b4533b6bb84a144c8dccca7e11de9b27eb1203'), 'builds/windows/visualce/index.html': (420, '46966fecf2ba471889c14eb942ab20e0a5048519'), 'builds/windows/w32-bcc.mk': (420, '2532479f6e4b9548dff38d6b20761cd99439af06'), 'builds/windows/w32-bccd.mk': (420, 'd63717033679ab942b52ae7b56d8419ef96fb6e5'), 'builds/windows/w32-dev.mk': (420, '905779f68f28a53e667c08446b2a50e4eaa26f63'), 'builds/windows/w32-gcc.mk': (420, '32c2051a065795a668e1a4d9715dd10295bb084d'), 'builds/windows/w32-icc.mk': (420, 'fa1c6ccacc60ecb76867ca31fa84204cbea45105'), 'builds/windows/w32-intl.mk': (420, '6d049412be308116cc2f8fc819806f840121d3d7'), 'builds/windows/w32-lcc.mk': (420, '994612b5397a0ed99d95630e88c541cf40b45798'), 'builds/windows/w32-mingw32.mk': (420, 'd2d8a9e4e29100fa1317290e1cee5b149766cf16'), 'builds/windows/w32-vcc.mk': (420, 'bf4b3735f37c7c57afbbf325218789c1eb3b492a'), 'builds/windows/w32-wat.mk': (420, 'fe287682f6a335ecfa72dce32d3d9b1509d656f8'), 'builds/windows/win32-def.mk': (420, '741422ca782d8c21a88db60e7458e7ccaf91ce76'), 'configure': (493, '672bd44e4c69b16ef36c98134022342e511685da'), 'devel/ft2build.h': (420, 'e94e6c52b70f44af880d0a7eab2bcf87dc918b42'), 'devel/ftoption.h': (420, '8e630ce05f96fbfb657264b164e2f943cdca8138'), 'docs/.gitignore': (420, 'b8d05d11a52f543f5fdbd336f9c3cdc3a751f593'), 'docs/CHANGES': (420, '59f450b14a56c111d1a93b821e76db95a2cd053c'), 'docs/CMAKE': (420, '31237ae15164709f4bc88ed1a8a63d1436d959eb'), 'docs/CUSTOMIZE': (420, '890c8abdd293b99bbea67beaf24d7aeeee299924'), 'docs/DEBUG': (420, '408b52fbc26a671c9ec915e77994741941d6461f'), 'docs/DOCGUIDE': (420, 'd031185267d31a8c09e767f4e91a6a47058b2f16'), 'docs/FTL.TXT': (420, 'b9e8cbd66ffff526113350953f4a2f4252a92f49'), 'docs/GPLv2.TXT': (420, 'b2fe7b6af3535ebc1e018dd2fe6c993330c031fa'), 'docs/INSTALL': (420, 'f576efec85437687be2c5fc4f93aca31bc450e01'), 'docs/INSTALL.ANY': (420, 'd92b27cb504cad034ece99eca1ef73b52e4669e1'), 'docs/INSTALL.CROSS': (420, 'd417fbd12f0711faa788ce5e6032082738e70dd7'), 'docs/INSTALL.GNU': (420, '766f6f8a1cccf0650fbd989f9e203cdc4d663347'), 'docs/INSTALL.MAC': (420, '2587e24a65c94473492873e6f113a3676440600f'), 'docs/INSTALL.UNIX': (420, 'acbd11e6edba0302a3a10711ac20cc5e2b257771'), 'docs/INSTALL.VMS': (420, '4c9a97de0b2a363954686896d6a81eed04d176d8'), 'docs/MAKEPP': (420, '4450e4770069e8bcafa180c0458258265d29e7f6'), 'docs/PROBLEMS': (420, '40bdc35a67629030515b4d7aaa803b5844a4b6a0'), 'docs/README': (420, 'c2b5af865011d6802e44f2406098bdc9c8f79e43'), 'docs/TODO': (420, '7c7987d1dc500e5ab52cacf69d43bf37915a2a64'), 'docs/VERSIONS.TXT': (420, '92a1a3368e16c92162b76809ad92c3cb44d55f17'), 'docs/formats.txt': (420, '13b3eb2a297b837ccb0b7630d1e3767811bf78e3'), 'docs/freetype-config.1': (420, 'e3e873aa60b946d1599b194fd02ef4bb136b0a91'), 'docs/freetype-web.txt': (420, '0c9140c50b383e2f2d601e25302bb695aff08558'), 'docs/markdown/images/favico.ico': (420, '8464e77ad3587b21e6b2dfa38491cc17bd5d6743'), 'docs/markdown/javascripts/extra.js': (420, 'b1ce774fac4076e78d0ba1eb122481ea5fcc6b0e'), 'docs/markdown/stylesheets/extra.css': (420, '5d999ed5d2015b8196b0f3007943b648146d3569'), 'docs/oldlogs/ChangeLog.20': (420, '52142ccb218a4985a0f60133a05055089fce4a1a'), 'docs/oldlogs/ChangeLog.21': (420, 'f2c18777392097e640f63d37e299ab40746a19bc'), 'docs/oldlogs/ChangeLog.210': (420, 'df163d0f7873f450799085484457509e966b7256'), 'docs/oldlogs/ChangeLog.22': (420, '5a5598a00b1c810c3937532e80af8bbc7f11ef6d'), 'docs/oldlogs/ChangeLog.23': (420, '7a5006ea9a3b062b6a60eff79ad9a38b919238b4'), 'docs/oldlogs/ChangeLog.24': (420, 'ba684fc26479c566376dc71cb8ac53643da2a909'), 'docs/oldlogs/ChangeLog.25': (420, '01d61fced5207a0f453fb369680c34bf7167471c'), 'docs/oldlogs/ChangeLog.26': (420, '02b3f9a680061264ef3781e92fee897c86209663'), 'docs/oldlogs/ChangeLog.27': (420, 'f58f84bc5274bb6aba616604ce66bc8148141740'), 'docs/oldlogs/ChangeLog.28': (420, 'e3310fb4dea2d888e3b74add0838a331e2b22aa4'), 'docs/oldlogs/ChangeLog.29': (420, 'b6629a48ac13b78ca882278874bd4e79e3c0d943'), 'docs/raster.txt': (420, '3ba8154fcb79ed87c2e3c359480511c3d76800ab'), 'docs/release': (420, '459f54e9e92eb76deec9164939f0ec9c8365d1a8'), 'include/freetype/config/ftconfig.h': (420, '9800e99adf950bb887e2fba4e851540856c58f3d'), 'include/freetype/config/ftheader.h': (420, '24a9161e2f113e3eb78afb6ca12719f696da5605'), 'include/freetype/config/ftmodule.h': (420, '028e52cc33c675fefafb2d17c7cb83ca208e5580'), 'include/freetype/config/ftoption.h': (420, '6d3d7dfaa574d8387b6eca249b3a13f9f57c0360'), 'include/freetype/config/ftstdlib.h': (420, '1c63e8d654c1c0aa2828ed78f8cb6735cd5688c9'), 'include/freetype/config/integer-types.h': (420, '4ab4c0c78bd34e3eacc66bb0ac27aa5b9cbc889d'), 'include/freetype/config/mac-support.h': (420, 'ac48995320fe9b9e4bd5dad905b2012d0e515ae9'), 'include/freetype/config/public-macros.h': (420, 'c76509a99f7f784390e7895683779b78d3c3fbb4'), 'include/freetype/freetype.h': (420, '0a330c7c3f660795e4e96f1b22970bebd3eee1a2'), 'include/freetype/ftadvanc.h': (420, '876a8a55cb9fc233b0807aff69e1a62acee3cc1a'), 'include/freetype/ftbbox.h': (420, '0107d94986bcc137709c27dfc7acb315750b04dc'), 'include/freetype/ftbdf.h': (420, 'fb1f318648612c4eba7c08e697b8442882d5457a'), 'include/freetype/ftbitmap.h': (420, '1df5f29aca1ab769611b4d4c30a64022015a5dcc'), 'include/freetype/ftbzip2.h': (420, '732931d22714141f32b559bb6d4da7f7373b5555'), 'include/freetype/ftcache.h': (420, '97223e36ec6b3fe99f3d0e77cb305b9d17c46b98'), 'include/freetype/ftchapters.h': (420, '7566fbd10f83de079bea84947b1f7d56fba720f0'), 'include/freetype/ftcid.h': (420, 'f9744716d986da9f510777e3ca2ed116b475205b'), 'include/freetype/ftcolor.h': (420, '1cce747115731210c0f866cc037ad812d70a8961'), 'include/freetype/ftdriver.h': (420, '39635f86c3ecce552d76141d9af12a2acd72b155'), 'include/freetype/fterrdef.h': (420, 'ce3817e55df3ac42a72fcb5b5662830294fda97f'), 'include/freetype/fterrors.h': (420, '218c4610e21800220ef5d7588768eb1d3691e22d'), 'include/freetype/ftfntfmt.h': (420, '2ea0c5f4d708a2cde24fe3d81f969cd10c04c6da'), 'include/freetype/ftgasp.h': (420, '632b536b471a25d84e26f4f816a200b269e0182d'), 'include/freetype/ftglyph.h': (420, 'e967110e81eb7e0c0d1046536611df0dc84b6ce4'), 'include/freetype/ftgxval.h': (420, '546a4818b6cd641b81a15a92b60dcc9d64e50650'), 'include/freetype/ftgzip.h': (420, 'f0c1550f61d36112612183e6a49912a5f57112c8'), 'include/freetype/ftimage.h': (420, '61de54e48cbbe83ef47462314483b6e96bbfdd7f'), 'include/freetype/ftincrem.h': (420, '32637fe5af02e2ae1b1e5c41124ef72e4fe81baa'), 'include/freetype/ftlcdfil.h': (420, '72dbe2acccbb5df2ee78c51668d70d19f4ee4896'), 'include/freetype/ftlist.h': (420, '74b3ffaee9f14b122a5361bfccf81ffded054995'), 'include/freetype/ftlogging.h': (420, '1670b12caf51a2d0f8f7c2954c7b240a68a2492d'), 'include/freetype/ftlzw.h': (420, 'ab2a9b7d5a853a19c2ecb349bc0c118c15db7a48'), 'include/freetype/ftmac.h': (420, 'a3ed7fba6f735a477816f04f235278b978e43617'), 'include/freetype/ftmm.h': (420, 'fb239bda1223a48bae5f4cf8aa982b426df97adc'), 'include/freetype/ftmodapi.h': (420, '7af33e33afee787703a7462b6921a9f4bae608ef'), 'include/freetype/ftmoderr.h': (420, '9010c9fc489a49d378dcbffc80b0bb0ec5e19980'), 'include/freetype/ftotval.h': (420, '66ac5871dcc832b164756e8b9b15097fd0e461c3'), 'include/freetype/ftoutln.h': (420, '68cf65bae15973c543756f342567d8b2e7d60ec4'), 'include/freetype/ftparams.h': (420, '3f6af8681f3b64cd9f552f3c63017905bc0445b5'), 'include/freetype/ftpfr.h': (420, 'abcd3880087350bf05ec23bebd70793dd63318c9'), 'include/freetype/ftrender.h': (420, '292c797cce587776c5c54b1a3dd1cfc9977765b2'), 'include/freetype/ftsizes.h': (420, 'f609eb2d76a705329d6ab1356f227a8766ae8536'), 'include/freetype/ftsnames.h': (420, 'f5511495f048cdb089bd9f5934e4d40754e4c6e8'), 'include/freetype/ftstroke.h': (420, 'c7f1d4643f04a2de62869e0061e02ea374f5045e'), 'include/freetype/ftsynth.h': (420, '90b4b19c25f88ba673eb6b6c739fb5b64e2adc72'), 'include/freetype/ftsystem.h': (420, '2ad3d7286dc776518cbd617fdba8fd3800dd6a6e'), 'include/freetype/fttrigon.h': (420, 'ebedc3a8d1ebb13c9377716104750727d4e17227'), 'include/freetype/fttypes.h': (420, '2f3ca05955a030fe20c9be6c7dd2b3d008635927'), 'include/freetype/ftwinfnt.h': (420, 'b95cad0a42209bf8de551e560f01a0ee11080dc1'), 'include/freetype/internal/autohint.h': (420, 'a22d8af7cd98b61d9aad6f59e08250b3dc3f35d5'), 'include/freetype/internal/cffotypes.h': (420, '8d6acbce7acbdb7911fa6bba086e061b0df9c220'), 'include/freetype/internal/cfftypes.h': (420, 'd474dcf40ea75cc8453e994a050e76af80961c91'), 'include/freetype/internal/compiler-macros.h': (420, '4863d6de75e89722595ce1ef35234f4788846332'), 'include/freetype/internal/ftcalc.h': (420, '129366f38949b07877e86d847c1520ed5da2d692'), 'include/freetype/internal/ftdebug.h': (420, '1baf5f385a8499a9cb304531567d68f09cf83e5f'), 'include/freetype/internal/ftdrv.h': (420, 'd52fc84f0fd926df3771388c1030dc9fe6c5d795'), 'include/freetype/internal/ftgloadr.h': (420, '902135e460cde79b973bbd3e3ff967b35dc6ebdd'), 'include/freetype/internal/fthash.h': (420, '642d21e21c6afb73b0d1bdd50c8a78c98af9810b'), 'include/freetype/internal/ftmemory.h': (420, 'ca840cb510be169caab470f94586e768cb653e34'), 'include/freetype/internal/ftmmtypes.h': (420, '854798ad3c0e87a391d3f626f0d4cbf73f7f3a0b'), 'include/freetype/internal/ftobjs.h': (420, 'f97262ffa95148629a076582db00dfaf6184a48a'), 'include/freetype/internal/ftpsprop.h': (420, '5967199a3bc9026967ec675b098311878c664e0b'), 'include/freetype/internal/ftrfork.h': (420, 'd0bb6b5bb0022019b5e8d21426363e4ec2acd886'), 'include/freetype/internal/ftserv.h': (420, '3b326627074d6eb214ccc9162742f2406601cdba'), 'include/freetype/internal/ftstream.h': (420, 'd60cd481c893fe7d3ff7c2b6fa5bf73b2e4f0a77'), 'include/freetype/internal/fttrace.h': (420, '22291ef7cfe5ead9ca7701524284b9711a0b1808'), 'include/freetype/internal/ftvalid.h': (420, 'fbcf2c63efafe8d7de217d86bc517bd226a61446'), 'include/freetype/internal/psaux.h': (420, 'ee574fef11b1ad9fba14ae561c97f7f8a7fe9dd4'), 'include/freetype/internal/pshints.h': (420, 'e7adcd380587d5139c6d8fd0c599b7380f959766'), 'include/freetype/internal/services/svbdf.h': (420, '52212cc7a2b8d7bee9241ceb42ce07e0bd1a5a2d'), 'include/freetype/internal/services/svcfftl.h': (420, 'ab29dede537e9d8833609baa25efd478e7722e53'), 'include/freetype/internal/services/svcid.h': (420, '9063211ee01773fc57a0103575627d9d4e389030'), 'include/freetype/internal/services/svfntfmt.h': (420, '91a6f007aa52cdec84644201d8f0cba1c2d8076d'), 'include/freetype/internal/services/svgldict.h': (420, '6020f9f78a6eb52d563b166e8bc9af4c2252f7de'), 'include/freetype/internal/services/svgxval.h': (420, '056114e6f8cc6f43448d0ff79ca07d85583e4b8f'), 'include/freetype/internal/services/svkern.h': (420, '7a06a01e8f019cc3a4fe2b0f97fa9605de9d3373'), 'include/freetype/internal/services/svmetric.h': (420, 'b6559d2b1ad33b2bbb368a65c3659791360aec0d'), 'include/freetype/internal/services/svmm.h': (420, 'fd851dba120f7c965bd06c7875d2d47b016de65c'), 'include/freetype/internal/services/svotval.h': (420, '487dca3f04353242a3fb5f8c204c6847621eba4b'), 'include/freetype/internal/services/svpfr.h': (420, '94cd695eb00f328004b124a31c014cf195663dba'), 'include/freetype/internal/services/svpostnm.h': (420, 'd99f4f681ef43085d5227aaee75a288638766435'), 'include/freetype/internal/services/svprop.h': (420, 'b6cba4c7f42bbf163d5969cf7b75bd54a17928e0'), 'include/freetype/internal/services/svpscmap.h': (420, '310eb53f33301ce15ebc5b5931ece4a9842c8e82'), 'include/freetype/internal/services/svpsinfo.h': (420, '78725a48fa5dab363e5d3daea2b84de821f6795b'), 'include/freetype/internal/services/svsfnt.h': (420, '0ce5aca13761a221386b0b2065440e425213c78c'), 'include/freetype/internal/services/svttcmap.h': (420, 'd7ad8066b5ee83a3a12ab36b7f243996cfc87a32'), 'include/freetype/internal/services/svtteng.h': (420, 'd4a9bab6ded8f429a3b893d029a5b3546304e9c9'), 'include/freetype/internal/services/svttglyf.h': (420, '528238024baa71292ce162ca4b3a5eb5db509038'), 'include/freetype/internal/services/svvarc.h': (420, '753340904d6674db40fc6e3ce7c3743d2c0eab7b'), 'include/freetype/internal/services/svwinfnt.h': (420, 'e5a3a6649b6fbbb684ba3d503bd6d26112f3fdf5'), 'include/freetype/internal/sfnt.h': (420, 'cc1ac7a6e4cf23561b8546f9efcd691eb770b924'), 'include/freetype/internal/svginterface.h': (420, '3a4ca314ddb2ea061e337b46f1ab9eb5657ffdd3'), 'include/freetype/internal/t1types.h': (420, 'e39076f19563198b060ff9a3f10fe0f91046f29e'), 'include/freetype/internal/tttypes.h': (420, 'ad45da39b994ac3365c831b3e3475c2dca9647ec'), 'include/freetype/internal/wofftypes.h': (420, 'b8ef95e27aada7a0295f73e688fca736f0a3a05b'), 'include/freetype/otsvg.h': (420, '42330a703b0285aad808f4121a7b321fc6092fe1'), 'include/freetype/t1tables.h': (420, 'badfdf40762dfafa1d9e86d5515498788cd5d550'), 'include/freetype/ttnameid.h': (420, '76ddb6f0a51ad5f3cb45b0b91873b33050b7e83e'), 'include/freetype/tttables.h': (420, 'a2ec304483a509926e28192e74bcd77856139b17'), 'include/freetype/tttags.h': (420, '7d431cea490bb24c23efd53af8253d314f280b26'), 'include/ft2build.h': (420, 'ffbf4a1e6ad1549b783c4351e42ca8d5ef014bb8'), 'meson.build': (420, 'fe26d30ff3444e625db0235eaa022b7a483c03e6'), 'meson_options.txt': (420, '67d0fa313371e84477eefc72a5dc4c730bac7b2b'), 'mkfile': (420, '2986bd12fdeae369c440b38533646c45b67bfcad'), 'modules.cfg': (420, 'b9b4718f187364e6657105320e220222d5bc0a2c'), 'objs/.gitignore': (420, 'f8476208f65968980ca4799e7cdfc074f7d36f1c'), 'objs/README': (420, 'befb63e049201f146e061849628e43c54f3eb21a'), 'src/autofit/afadjust.c': (420, '6940baf68cc3152c2f0a9f1cae66ea016b194b4c'), 'src/autofit/afadjust.h': (420, '85dbfaad29e0222792235c0f950853c09e73ce4d'), 'src/autofit/afblue.c': (420, '77c8389ec7fe60835777db2a7ba5d1990930c314'), 'src/autofit/afblue.cin': (420, '70b7e025214d4956f5ba3f8a5771b555c0b3c521'), 'src/autofit/afblue.dat': (420, 'e62754fc7e06db9ae97a03e01232579649e22595'), 'src/autofit/afblue.h': (420, 'f124eedee4d171f8ae10932e5b4c31f60ccdd3b4'), 'src/autofit/afblue.hin': (420, '931c5010606cf3233e5fe7ee91bfdd7c12a08049'), 'src/autofit/afcjk.c': (420, '7a1cc32c9d46d7e1d8734698f04815ca2b67f2c2'), 'src/autofit/afcjk.h': (420, '98681868a85e6f0c3bc97bd5ae30c7b4f60b6c2f'), 'src/autofit/afcover.h': (420, 'd60e0050bece2aa73b5fcfe7308a660029c1dcc5'), 'src/autofit/afdummy.c': (420, 'f9d1dd38dba42aae0a39414b9731bdf218ca7476'), 'src/autofit/afdummy.h': (420, '14546b1e50e2775593f959e20d4fe436833014f2'), 'src/autofit/aferrors.h': (420, '3d7538ba2d885381560279c205e0d25771df4d90'), 'src/autofit/afglobal.c': (420, 'ff6903cc174aa7fe271d7f04bfbc9066613c8576'), 'src/autofit/afglobal.h': (420, 'c4dd93358398a0474dde9500f6844e891b73fa60'), 'src/autofit/afgsub.c': (420, '4a9b9ef69faa21c29bb3290a3a3d129551e5de2a'), 'src/autofit/afgsub.h': (420, '10884f9236e09f72a4051200d7e4c46d3d567f7b'), 'src/autofit/afhints.c': (420, '376912a5d1217e288190b1f9291375a095d805ce'), 'src/autofit/afhints.h': (420, '84244d6f5c70be9349ab99bd3984df4becbdf2da'), 'src/autofit/afindic.c': (420, '29b6d22ed650ab8aaaf82797c7ffc3f622442340'), 'src/autofit/afindic.h': (420, 'df4892a9f1ce28759d4fba36d947152403c6c168'), 'src/autofit/aflatin.c': (420, '3c97f91dd933c99a08ae770455ffbe85659a23f7'), 'src/autofit/aflatin.h': (420, 'b6bdc5177f7f987b6fb4ba816cae4eb8a318add5'), 'src/autofit/afloader.c': (420, '8ac7b53856bcfef47fcf0985ca88cc70b3caf6ef'), 'src/autofit/afloader.h': (420, '8efd0fd57e9976cb0397ed6c686e867212d06b5b'), 'src/autofit/afmodule.c': (420, '57d5d47dfbda2ed2b999ac65c8a803e3c2d2f8f2'), 'src/autofit/afmodule.h': (420, '1f8a68122d3bcf121713a1398cb2060fb6eb7c4e'), 'src/autofit/afranges.c': (420, 'c9f5e0a8aab073f592462185a0e0c67bdc391922'), 'src/autofit/afranges.h': (420, 'f29369451286be69ad51d9cdaaa7f4bccc3a1a45'), 'src/autofit/afscript.h': (420, 'd071ed68b7e5a0f603e7fed288a92fee4ece7f48'), 'src/autofit/afshaper.c': (420, '3c0ffe09473547aa23881e885d2a9446d906af6a'), 'src/autofit/afshaper.h': (420, '6e73b9fb2ebdfa81d3a27cc5345c8a18127498a4'), 'src/autofit/afstyles.h': (420, 'e7a7fe531baac95f8c3c14b9215d47ffa92076f0'), 'src/autofit/aftypes.h': (420, 'a3a881eedeb0227391ad62a58025736ee6cde42b'), 'src/autofit/afws-decl.h': (420, 'ddebdcd1e785dcb799e54240429befa4dc205779'), 'src/autofit/afws-iter.h': (420, '720c2dc50c907529cf97b231821fef75baa9cd09'), 'src/autofit/autofit.c': (420, '8cd973bf147f28e452556645ffe7086d91693248'), 'src/autofit/ft-hb-decls.h': (420, '056b53a191d8edf493f33de8d8f73c7979fae256'), 'src/autofit/ft-hb-ft.c': (420, '05a66ad32f6790f7a5bc80a734df6452f599ef88'), 'src/autofit/ft-hb-ft.h': (420, 'f4f1d6291ff35d5dedc92a6163332ba77db77fae'), 'src/autofit/ft-hb-types.h': (420, '6176622f7caa58672a72737dc633366042cdd6c3'), 'src/autofit/ft-hb.c': (420, 'ed438da6afe62f7867e35cd3887d0df5e9a4d132'), 'src/autofit/ft-hb.h': (420, 'd2cc0482eb6b25c5b1ceb3592e118c0205a30770'), 'src/autofit/hb-script-list.h': (420, '1caa16aabe7f991579fc72ad178837fac3a525fe'), 'src/autofit/module.mk': (420, 'a82bedb9f2bd672bb3d864b8ab24784d0f7b2ec3'), 'src/autofit/rules.mk': (420, '9e39db33c90cc91aec7ec9a63463efe32022e3a6'), 'src/base/ftadvanc.c': (420, '6485834666624bac9dd9fc2e3085f21440ed19e6'), 'src/base/ftbase.c': (420, '5a5c8515982a1a39784f2c114a2abe6d183e309b'), 'src/base/ftbase.h': (420, '952ac51d503aac844a883898b2ec67749f185ccb'), 'src/base/ftbbox.c': (420, '4007a9314f085d83ad7843ed61df5ee1b4475e95'), 'src/base/ftbdf.c': (420, '7ce76d3c48446f67d00f0c996b4c7c437e9f45e2'), 'src/base/ftbitmap.c': (420, '1606cbfa09053b9a63b29e06da8aaef062ecd20b'), 'src/base/ftcalc.c': (420, 'c78d3b6da4b8f350bacbd356c27800d1e0845b76'), 'src/base/ftcid.c': (420, '878c666e12982584db1caabd901f49bd8c910ff0'), 'src/base/ftcolor.c': (420, 'ed6b5f0599fc08c85f155dc952a46fc4242a2ce8'), 'src/base/ftdbgmem.c': (420, '0335f142562a31eb662b5e333e7c2b7d482232b4'), 'src/base/ftdebug.c': (420, '27091a557984d45dd16b7fdba05af843601934e3'), 'src/base/fterrors.c': (420, 'a140dab860174bd46455715ac35992b36d796d44'), 'src/base/ftfntfmt.c': (420, '99e8c2b17dfe880f115c8411c34d8061a347e9eb'), 'src/base/ftfstype.c': (420, '58d5144a9e02a2893f72f91645ab468c147e11a9'), 'src/base/ftgasp.c': (420, '3c13456802e6823eceba9382b1ff009b9d9b3d54'), 'src/base/ftgloadr.c': (420, 'bd66e61d1c285fa1b68780d5dcacc005950e1b6e'), 'src/base/ftglyph.c': (420, '096f4d965e87268e614a0e505b45958fc3d1defa'), 'src/base/ftgxval.c': (420, 'e48f582c712a12f5b6dc3812507143e43e051cbd'), 'src/base/fthash.c': (420, 'ab248ace8bd01b3680767fb5b49d7e2ed46afbb4'), 'src/base/ftinit.c': (420, 'b20289316dc2ff3b6fb1a7f7e1def6e1d6392494'), 'src/base/ftlcdfil.c': (420, '9adbf7518f6060163c864f1bfac9b8909dd183e8'), 'src/base/ftmac.c': (420, '7251a4cb9621a74355425707195bcf7311360fdc'), 'src/base/ftmm.c': (420, '0d3bf3b77d847a2d1cab105a509ff2a3f402c50a'), 'src/base/ftobjs.c': (420, 'acefdf46fd9dbcf9134333e3777bccceaaf3f331'), 'src/base/ftotval.c': (420, 'ae14113612f6ab3d57918f6caaccf6018e4ecb6c'), 'src/base/ftoutln.c': (420, 'b37b53312fcd3d6f24dd22958ee82b77d0ac4b52'), 'src/base/ftpatent.c': (420, '3f149eb607fd52e3205d1d32350e5abec5294cd0'), 'src/base/ftpfr.c': (420, 'f95808201ab886b0de628d0fd1500e32d5b34a73'), 'src/base/ftpsprop.c': (420, '13f6c5102ccddfe7b22169925fc67517b74d5fad'), 'src/base/ftrfork.c': (420, 'fbb8ace7173a0fdbd61ff7221b6eae50633518b5'), 'src/base/ftsnames.c': (420, 'd8274cccd4063353a64e93d9af8f9b1808ec3c5d'), 'src/base/ftstream.c': (420, 'b08a1a9b6580545e66334423c4c6f226eec2bb47'), 'src/base/ftstroke.c': (420, 'cc93265b0ba210ca1435a3e2cbc647b2c6f82869'), 'src/base/ftsynth.c': (420, '23960eda3a96a1ebf524690160118fa9af896a01'), 'src/base/ftsystem.c': (420, 'be9159f6141ddb4e53efd019e5730f32da0c1dee'), 'src/base/fttrigon.c': (420, 'baa47eba08414b597e7ee5750b0b3f3f970c303d'), 'src/base/fttype1.c': (420, 'f9a46801f3ce30ae2139b9fe811fb74cd447237f'), 'src/base/ftutil.c': (420, '5d8fc7b9bf37f238c8cc461863040bf9bab8179c'), 'src/base/ftver.rc': (420, '9253f332cd443e3654690bd2bcefef816750725d'), 'src/base/ftwinfnt.c': (420, '038451ae0954bf5de202844912a6526e5fae46bf'), 'src/base/md5.c': (420, 'b235e17a56832cec9e3a7fccdf8c40149bc5aad8'), 'src/base/md5.h': (420, '2da44bf355a3a00b5abd283792e53efad339b1f3'), 'src/base/rules.mk': (420, 'e806066485f9df01e826e78cc7433622d9253945'), 'src/bdf/README': (420, 'd7cb8c14ef6d969fed46151803382c6ea9da7dd9'), 'src/bdf/bdf.c': (420, '249012e5907ed3d3cb9da2a8a081a54ed9aa119f'), 'src/bdf/bdf.h': (420, '85a9e4f2ec148e27d0fd396e11571126ae012b95'), 'src/bdf/bdfdrivr.c': (420, '94549b69224866e6c316c5f4d44bec67b609ad18'), 'src/bdf/bdfdrivr.h': (420, '54aaa3353cebcd1299213c65816dca48f368b6b0'), 'src/bdf/bdferror.h': (420, 'c1b54448714069d5ee4fb61a0caa963f69419c14'), 'src/bdf/bdflib.c': (420, 'ab6f6a9bf23c4ef771037fddc54932c8b560d884'), 'src/bdf/module.mk': (420, 'fe06ae8e0647446b8817a4f1d9ac6bd69a5b1fa0'), 'src/bdf/rules.mk': (420, 'd1dd76b1c3d8fcb77dd7d5b2f4d578875dd1f05a'), 'src/bzip2/ftbzip2.c': (420, '6326c71ac112bba1c574cca3002ffd8aff613087'), 'src/bzip2/rules.mk': (420, '3adf30653339ee27ca836cf476ece87b200682ae'), 'src/cache/ftcache.c': (420, '95f784370d1477492fd281e8c828f50e7e613e69'), 'src/cache/ftcbasic.c': (420, '81c5ded4737230502755fc3734739f3abe51279c'), 'src/cache/ftccache.c': (420, '28f3f3e7a0147b50f64bd8be00f4897b138f8f55'), 'src/cache/ftccache.h': (420, '55ecf5e70cb75202822fabbeaae8df2a182f31c7'), 'src/cache/ftccback.h': (420, 'f013833e66433dccc6159fbebe9a3abb469d6892'), 'src/cache/ftccmap.c': (420, '758468fb45939d1d37ba5c35a62d37c7a07dbd87'), 'src/cache/ftcerror.h': (420, '41491c2f46a08f15858e262a12c53e90987ce4b9'), 'src/cache/ftcglyph.c': (420, '3c291ce50fb8fa93b54fd7178d8df5ca69a588ca'), 'src/cache/ftcglyph.h': (420, '1777a17e53f83f201aadc98ba78ab5b52bea15c9'), 'src/cache/ftcimage.c': (420, 'b028bf8e45746e977fe662aaa286dc7ea9fa2aad'), 'src/cache/ftcimage.h': (420, 'd48c54c51b88f1996274cbaf6053f7bf0fc0929f'), 'src/cache/ftcmanag.c': (420, '4c1d85ab1f0f4ff9819092b560886b67ea726250'), 'src/cache/ftcmanag.h': (420, '22d56d7eb8477fe168bba27f2559a2b36757eb3d'), 'src/cache/ftcmru.c': (420, 'e8dc9052daa7b4ff5ff639a8743a215319f406c1'), 'src/cache/ftcmru.h': (420, '962d0886875d3ba5deaf8cdf0b4177eeec440fce'), 'src/cache/ftcsbits.c': (420, '7f6a9b1b4ed6db131c5d9429668011f21c252560'), 'src/cache/ftcsbits.h': (420, '669e77cb309c4adf47c8878275f7e61d90bc4264'), 'src/cache/rules.mk': (420, '6f56da94208c5434313bd77193976e7a014341bd'), 'src/cff/cff.c': (420, '8125c104d1f2089ad41eee62276e0bc6f16af7d8'), 'src/cff/cffcmap.c': (420, '75e2420d99e9ddedf41be113ff97c4d2425a1821'), 'src/cff/cffcmap.h': (420, 'e812e7a89e51d414318c28c48ad8da72140ce839'), 'src/cff/cffdrivr.c': (420, '935548ea647f55404d868fb7219238b624cb72dc'), 'src/cff/cffdrivr.h': (420, '2f3c58b67d77424823edc590334d40b8717a0682'), 'src/cff/cfferrs.h': (420, 'ca1158c0dfdc8aa927a46b136fb14ecbe04156db'), 'src/cff/cffgload.c': (420, '331c681b8ae2e4cd7ca28cfabe1a7756a7195c7a'), 'src/cff/cffgload.h': (420, 'eb4b5f30b5ea12caa838813820209427246a62ed'), 'src/cff/cffload.c': (420, 'cfd5317ff52a1522d3895ff27243cee1f669b2e1'), 'src/cff/cffload.h': (420, 'ab02ca2d7f640a0a7bfe33256c32f027e513c478'), 'src/cff/cffobjs.c': (420, '8efdd109f95cae0bb825400a70661348f61fd5aa'), 'src/cff/cffobjs.h': (420, 'c6ab805c5be98f2244ad5a36f41eb659e23a236e'), 'src/cff/cffparse.c': (420, 'fadc3258c9605216faadcb98a53dacc4c7b57fe6'), 'src/cff/cffparse.h': (420, '1daf548cbccabfe86bc7dee181b22dca5a4b235b'), 'src/cff/cfftoken.h': (420, '0eadc7118fb1bcfac1edf2c0fe5216b1d16b3416'), 'src/cff/module.mk': (420, '14dda50d6669652de04a22bbca962bb21a2a2e37'), 'src/cff/rules.mk': (420, 'f3a729db5ddccedb73d958ffa21803afbec5f900'), 'src/cid/ciderrs.h': (420, '00497b796b385ae47355dff9956621647ee7d199'), 'src/cid/cidgload.c': (420, 'cc68b4a96009ec533abb47172999407ee9db96fc'), 'src/cid/cidgload.h': (420, '51b16c75944b04dfddb619fa7cdc8f9adb1faa50'), 'src/cid/cidload.c': (420, '170ae2d1c7d22db2fb6423a4c938f621490c6df4'), 'src/cid/cidload.h': (420, 'cef7d1c9a6a184896188aa14ff0d912a9153e88f'), 'src/cid/cidobjs.c': (420, '2d11609598b8f167c5c647d7df788ebf45f97189'), 'src/cid/cidobjs.h': (420, '406646231278bd5d70e5a304cfb5a6f96bc241e8'), 'src/cid/cidparse.c': (420, 'fb936bd48d9a946e821259c43ebc7d512f9a9924'), 'src/cid/cidparse.h': (420, '555245230b92bdffe87b3d2a6eac3379622bf403'), 'src/cid/cidriver.c': (420, 'ab188776e2fd8a499b9d326817b6502042d53349'), 'src/cid/cidriver.h': (420, 'a4ddccec8082b7a108a0fb36c599f05029568038'), 'src/cid/cidtoken.h': (420, '22136310cdf7482b1e096b6244e6e062d55e5088'), 'src/cid/module.mk': (420, '2994e4777c15841743878d59788ae39eff138ac1'), 'src/cid/rules.mk': (420, '5569c7c5ebc97001529f701d25296425da48cca0'), 'src/cid/type1cid.c': (420, 'fbcce4f70bb271a364c8cdaa70623ec6c75f1b17'), 'src/dlg/dlgwrap.c': (420, '159af2d6751f2b51d7a8dc4a95c47834a62bf9f4'), 'src/dlg/rules.mk': (420, 'f575a8bd1e2d0a0c92dc7cc88058df26d110c7fa'), 'src/gxvalid/README': (420, '1bde33300e59a02dd7fe52c2b1a99164afe646e2'), 'src/gxvalid/gxvalid.c': (420, '93c10f127d6adac08f67f182480e1698fcea5767'), 'src/gxvalid/gxvalid.h': (420, 'ee76946147cee6f4e48ac935281b2b772fdb88e6'), 'src/gxvalid/gxvbsln.c': (420, '9b9c10b9805f6e026b398193b619b6f769c2376f'), 'src/gxvalid/gxvcommn.c': (420, '111db5c693de6353f2c36f08dc671df69d39e69e'), 'src/gxvalid/gxvcommn.h': (420, 'cc95c4cece1077b5133dd5790c3645fccaf92447'), 'src/gxvalid/gxverror.h': (420, '90a6eda03ece81d952f0aa688c8a822b09c6c494'), 'src/gxvalid/gxvfeat.c': (420, '826f3eedf5cbb435d814b253b8b32a92b58406cf'), 'src/gxvalid/gxvfeat.h': (420, '9d34b701a29512e683d3db573e1d0f4cfa6dcde1'), 'src/gxvalid/gxvfgen.c': (420, 'd0c53ca5261c252a41832fbdc744bfd33814a456'), 'src/gxvalid/gxvjust.c': (420, 'c5177522e3855e46d13cab9565f9c309ce69c772'), 'src/gxvalid/gxvkern.c': (420, 'f1f8ce7cd36515d7b64a52c6798f3ab4f3e0d555'), 'src/gxvalid/gxvlcar.c': (420, '7b90d43a7b3d50cafea766c0198c6bc28fd206cf'), 'src/gxvalid/gxvmod.c': (420, '89e142be5dcbd861b92555797ac2dd8608b9f537'), 'src/gxvalid/gxvmod.h': (420, '51e339e00be4205950de5b46548a4befd182a762'), 'src/gxvalid/gxvmort.c': (420, 'de03f2e3888518e56de6c8cdf727c3dd7ad978b9'), 'src/gxvalid/gxvmort.h': (420, '3db0d2a61e015062d3aac5bc5289435cc541bb43'), 'src/gxvalid/gxvmort0.c': (420, '78b042d5dedec1682ab6e5dfd2b2a72bc571861f'), 'src/gxvalid/gxvmort1.c': (420, '57ee197d4895c1bc847e3bef367fd487c90fb40b'), 'src/gxvalid/gxvmort2.c': (420, 'e982a67bf520e11af5a358c76c66b2ce23e56d73'), 'src/gxvalid/gxvmort4.c': (420, '2ad0632fa502085feb24bec1f1f549e19765e61d'), 'src/gxvalid/gxvmort5.c': (420, '613debd453750215f11d9e9fdc4b9c623dad51cd'), 'src/gxvalid/gxvmorx.c': (420, '9efe182038df1eeb55a89139e03d07a615e18f09'), 'src/gxvalid/gxvmorx.h': (420, '60b084a8d0b69ce42b6ec7c2c95d1950a482cd56'), 'src/gxvalid/gxvmorx0.c': (420, '54cded1f6465a1e86d8889a320b9342291b486e2'), 'src/gxvalid/gxvmorx1.c': (420, '56a64c257cf825b684ec03647ab6b81c0b7b9fe6'), 'src/gxvalid/gxvmorx2.c': (420, 'be333e0424bcaa83856a95a1db030ddbe9e0f746'), 'src/gxvalid/gxvmorx4.c': (420, '9af41f4bf505240f652f15e67432d11d9d712538'), 'src/gxvalid/gxvmorx5.c': (420, 'edc3f3bc01905f21bb5337ab0b9e69c554b6e323'), 'src/gxvalid/gxvopbd.c': (420, '265ad39a2ca2177eb76ab9e40291c34e3ca6de07'), 'src/gxvalid/gxvprop.c': (420, 'f27ce103c48be0af285996a67b50432b90f36243'), 'src/gxvalid/gxvtrak.c': (420, '06300beff342fc3fe19315d44311cd9fcb25cb68'), 'src/gxvalid/module.mk': (420, 'd6b58ee922e15aebaece85e9d65dad084b255294'), 'src/gxvalid/rules.mk': (420, '552f64dcc38afb98b8554a24ca25954e963bb356'), 'src/gzip/README.freetype': (420, '5d8b83d5dd783a68bb7382220009f5d3db96ff84'), 'src/gzip/adler32.c': (420, '260185b672f75eb6722fb633e29eadafbb750027'), 'src/gzip/crc32.c': (420, '6624c0ec5d0ab00ce209a0397eaedf213b4db6a1'), 'src/gzip/crc32.h': (420, '137df68d616c5ed38913579ba37b4e4c533fa903'), 'src/gzip/ftgzip.c': (420, '4a5ec87297402602e5f7dda10771726bd71eb688'), 'src/gzip/ftzconf.h': (420, '62adc8d8431f2f9149ae0b1583915e21a28dd8b5'), 'src/gzip/gzguts.h': (420, 'd7d733bda71b46c204930b73eebcec23ccf97476'), 'src/gzip/inffast.c': (420, '9354676e786ee7a6a31668adf9d25c712d57e657'), 'src/gzip/inffast.h': (420, 'a38c5be450ac4ca71891aa9fc3e062d7d332fba4'), 'src/gzip/inffixed.h': (420, 'd6283277694802ce7938f537f12990d6eead4924'), 'src/gzip/inflate.c': (420, 'c8125680b0c9440b6c639e54c96ec039515a3a2d'), 'src/gzip/inflate.h': (420, '8a0e437aea39470f66cd3afd07ac80060d05a23f'), 'src/gzip/inftrees.c': (420, '468eea8790a257c073771df5df572b1a4f301ff3'), 'src/gzip/inftrees.h': (420, 'd735b0a5145f3ba283754f50f352bd9732d754e3'), 'src/gzip/patches/freetype-zlib.diff': (420, '9c7e549c6e86e748110d9024e629c09079b9d219'), 'src/gzip/rules.mk': (420, 'baefc0b9bad85027ceb5341b447c145b47070497'), 'src/gzip/zlib.h': (420, 'fda054163ea593959cdfb074959cb3b89029920e'), 'src/gzip/zutil.c': (420, 'f76def425c7f701f6ac239923f2b39c89dfb4514'), 'src/gzip/zutil.h': (420, '2c96797e3ae73ff2c5a7809780ff891e021a7371'), 'src/hvf/hvf.c': (420, 'a0e0a58ce10a4d44e51cc67ad7b26ce77318bc64'), 'src/hvf/hvfdrv.c': (420, 'b59cb55c93f6cc8c39b9960344cd3ad1e30b1db1'), 'src/hvf/hvfdrv.h': (420, 'c27d7fcaa19753456ea0b18e639341a05be5b47e'), 'src/hvf/hvferror.h': (420, '6d474d292cf5762489897927c7afb562eca720e8'), 'src/hvf/hvfload.c': (420, 'a02d363c1da6fa8f4c2cf054cffa0ca914697f6a'), 'src/hvf/hvfload.h': (420, '0207a55e5ff05ce90bf96661eabb0309683def84'), 'src/hvf/hvfobjs.c': (420, '96536b8ef15b9989a4a22433f2c9310fbb64aca1'), 'src/hvf/hvfobjs.h': (420, 'ae9c90595e8122f2b9e152a8eaa987be506ff5b9'), 'src/hvf/module.mk': (420, 'b404119e881ca27b28d72d46f67d87511018e43e'), 'src/hvf/rules.mk': (420, '7083ecefb0b0a548bedfc58c416d41366d699f04'), 'src/lzw/ftlzw.c': (420, 'ce5070d75fa4ae6329f33b055a20e1d5eaf1dcbf'), 'src/lzw/ftzopen.c': (420, '3a42824902f425d04527e381ff814bef48b97413'), 'src/lzw/ftzopen.h': (420, '9c06b367d86a87d0925ed0a649eb2a1fa81ba72e'), 'src/lzw/rules.mk': (420, 'ec996bb918a262a2d17a68d308044803060d84ba'), 'src/otvalid/module.mk': (420, 'dadc349f3a74b5dfb85db9f7a4c75d0376832069'), 'src/otvalid/otvalid.c': (420, 'e68a0823fe7cca2b808e63e04f945a0443026593'), 'src/otvalid/otvalid.h': (420, '6ab7c65cb42475b79d09536b4c41c652c645111a'), 'src/otvalid/otvbase.c': (420, '8cea1319395ef6d94477196ab51773a3d7552222'), 'src/otvalid/otvcommn.c': (420, 'a6771c782658cf1a6b321d8d40bdd516733d8c96'), 'src/otvalid/otvcommn.h': (420, '4648e70dee2bbdc86586fcf01f7252dac430d380'), 'src/otvalid/otverror.h': (420, 'd1c2c4b56cf2d65fb87cab30680236aac287eb98'), 'src/otvalid/otvgdef.c': (420, '08d0a68d684b448d5a613d24835d2db6468c9b7e'), 'src/otvalid/otvgpos.c': (420, 'b9e36bd833b5ca97c75d086a9e1993ede27fcab1'), 'src/otvalid/otvgpos.h': (420, '8539801fd9388fbab90edfd47c2112615b67e662'), 'src/otvalid/otvgsub.c': (420, '2669be37c9fdbb97390481eea300cbbc79d690d2'), 'src/otvalid/otvjstf.c': (420, '6706e1a7f886486da8f94cd863a14525f03c3e6e'), 'src/otvalid/otvmath.c': (420, 'ccc4b89d296f40d205e1c6c41213bd569e75048d'), 'src/otvalid/otvmod.c': (420, '946c81902fd25bdedd256ab3074c58b58a0b6bf5'), 'src/otvalid/otvmod.h': (420, 'f00f98f12509507822be1c41bd1df1574d5f6535'), 'src/otvalid/rules.mk': (420, '83c426829d657b07f3d9b50b922cb296cfc6c43d'), 'src/pcf/README': (420, '09ea970edadb5247e7209e5e0a3d3d30c2a7210a'), 'src/pcf/module.mk': (420, 'df383ff0fbecd8f6b518f4c72fef9a7ee95b0450'), 'src/pcf/pcf.c': (420, '6b30fb249a709a0fe5d7cbba59bbd132f8f53983'), 'src/pcf/pcf.h': (420, '3134cc355b355e97e649ce39921aa653c860e19b'), 'src/pcf/pcfdrivr.c': (420, '11977c51edbe10b3759d2bfaaa348433a327121c'), 'src/pcf/pcfdrivr.h': (420, 'd4653937434bb896cfa350d3b2cbb4dd2e35c617'), 'src/pcf/pcferror.h': (420, '8b9e9902a36a1e823393c335053a9a5454b3cb5d'), 'src/pcf/pcfread.c': (420, '49d5171630d349e7444a420bb037e258b0649dba'), 'src/pcf/pcfread.h': (420, 'a54648fbf98e097908fb094c9367dacbce158264'), 'src/pcf/pcfutil.c': (420, 'cd26c77cadf2a00e4855c974eae84a41a96e99b2'), 'src/pcf/pcfutil.h': (420, 'a197c1559514a40cb278f2e9e2e981ba0e2813b9'), 'src/pcf/rules.mk': (420, '1b55daf4f43b245892a4f6c848e9292de6e6d063'), 'src/pfr/module.mk': (420, '9d57e36bb5d8ae0ae0de7fb7510e4903b6c36141'), 'src/pfr/pfr.c': (420, '260c2703cef7b67de64dcd5cdb481b9bfde94955'), 'src/pfr/pfrcmap.c': (420, '786aaa1163e59eca40f705591542d941c1ed8641'), 'src/pfr/pfrcmap.h': (420, '9ebb3f23daf01e00ac026c32c3f86baa44d69e2d'), 'src/pfr/pfrdrivr.c': (420, '31f3509bb7dbeaa10e2edcd1c81b5456457430bd'), 'src/pfr/pfrdrivr.h': (420, '2c75a14d78981e2660b0c4aae9f0053be7f61ad2'), 'src/pfr/pfrerror.h': (420, '78cbac32f88c83f0a3ee9d9ddcf1398c2f508c77'), 'src/pfr/pfrgload.c': (420, '68849b4a11315c204dd0b5f2c0d19e766705e083'), 'src/pfr/pfrgload.h': (420, '81a05327835832367eb99e96f0056744f68dcd43'), 'src/pfr/pfrload.c': (420, '1105ba4812bb5e43fc733c351f4133627d699705'), 'src/pfr/pfrload.h': (420, 'a2f3bcc3df92758c79d2a9c79890d3583c12a594'), 'src/pfr/pfrobjs.c': (420, 'bf538e20e54c533bff8e7673e32143a07e7772b0'), 'src/pfr/pfrobjs.h': (420, '3ad74e97d37b7d0beec0e05c5783f66ed1561a22'), 'src/pfr/pfrsbit.c': (420, '515089a65b6345315314903ae46018b052e09633'), 'src/pfr/pfrsbit.h': (420, '639f8c8182aee840927013e43c257975b12bd449'), 'src/pfr/pfrtypes.h': (420, '54cc09ca39560ce2e8ef7dc3a5bc464976558c6d'), 'src/pfr/rules.mk': (420, '842d88eac6066d792b1cf318eaf213091157b0f0'), 'src/psaux/afmparse.c': (420, '1cc8ab29d46a04b309ad71ff314e4cf253e8bfe1'), 'src/psaux/afmparse.h': (420, '02a9617b8dc4881b24ed328e5631e81409474922'), 'src/psaux/cffdecode.c': (420, '908a81126153418c61faecfd56a528f7daee8957'), 'src/psaux/cffdecode.h': (420, '0836a642b2ff2a67e6687c93b97e4b98b5934ecc'), 'src/psaux/module.mk': (420, '2c6ddacb96770c1b520c7aa3678d1b2d98f6fde0'), 'src/psaux/psarrst.c': (420, '70313d283a455ad7e9ec8667f9966c7934bfcbef'), 'src/psaux/psarrst.h': (420, '31e5330cc3808be6a5cc92f52a93cac2fb942035'), 'src/psaux/psaux.c': (420, 'f0c3c2ef97b5afa537e5930ffcbf167762e2b6ef'), 'src/psaux/psauxerr.h': (420, '5766482d1b708a7b0dc76518112f6673e20cea87'), 'src/psaux/psauxmod.c': (420, '2f9eb87484cb7f20431a945e795bbaf3f94aeec6'), 'src/psaux/psauxmod.h': (420, 'e7fa15c34b7979baa0f2011ac6edd36bce84eca4'), 'src/psaux/psblues.c': (420, '213b943b46576ddcca6b471cd5d3d0cf4d68acb0'), 'src/psaux/psblues.h': (420, '55fb88ecddfa1dc8a184a9e3d232b90ccfd16a91'), 'src/psaux/psconv.c': (420, '3a054cbbf6d885e8371f1d2a8966fc232d351bab'), 'src/psaux/psconv.h': (420, 'fc123faea4d775cdac45d675d6c4c51efb3e6a46'), 'src/psaux/pserror.c': (420, '98cebcf74d99ece4a36065894e6ace54cc8c9ead'), 'src/psaux/pserror.h': (420, '5738853face775a7944ebbf9c3e02958a93bd3a4'), 'src/psaux/psfixed.h': (420, '299d076370504844152c984f9c562a753139638a'), 'src/psaux/psfont.c': (420, '0db1f0c5bc460f5040e62c09295efd81cee08aca'), 'src/psaux/psfont.h': (420, '836fce4e4d32f6bca4cb695de49163ea8d4eb204'), 'src/psaux/psft.c': (420, 'fd0abe17154c71250566365ddce401c994288d5a'), 'src/psaux/psft.h': (420, 'd9082f3a2be120bd80edfaba983112a19324d91d'), 'src/psaux/psglue.h': (420, '63085d71cf50881c277808ea0980a31b19f0b0c2'), 'src/psaux/pshints.c': (420, '7bd08a9c9bf86af8d710c5566b305d6a0439847a'), 'src/psaux/pshints.h': (420, '31a8230364c3493199e3ca8fcf9cbaf6b14c4e86'), 'src/psaux/psintrp.c': (420, 'bb8efc8156feaffb42df1080b9283ddbe8e3411f'), 'src/psaux/psintrp.h': (420, 'd8b9342ecb61fd326b5f5e7d82fea5b3004cb321'), 'src/psaux/psobjs.c': (420, '5019f9925c1eb9644af70afe8165fb46fec781b5'), 'src/psaux/psobjs.h': (420, '04205f891b17194e2faac5ac76ded4da7571bb57'), 'src/psaux/psread.c': (420, '7f657f2cdc02da4bca7d02bf0aec05e9dab6830b'), 'src/psaux/psread.h': (420, '9e55fe044703042b55ef3371494cb204584adc12'), 'src/psaux/psstack.c': (420, '1360ba30dab7ef9827d62030e457a06fdea91cb9'), 'src/psaux/psstack.h': (420, '907b42400074ca510a37aa3230384d9e1659313b'), 'src/psaux/pstypes.h': (420, '435ef7e1fecff79263eabef658d215c193ee3f70'), 'src/psaux/rules.mk': (420, 'ace45afb4670a98e840091f22064d37393c6810e'), 'src/psaux/t1cmap.c': (420, '686ca7abdfa39210308797e279b83f3747fc1756'), 'src/psaux/t1cmap.h': (420, 'be66a0c7f6f4c31af8931867177793f36abd74f5'), 'src/psaux/t1decode.c': (420, 'ece512412da92fc1342883773181d62476b5a463'), 'src/psaux/t1decode.h': (420, '1b5d5205a865413e134136cd4e51b05d1130e0bd'), 'src/pshinter/module.mk': (420, '96aa535228a3dd3d6bb170ea6d86886cc1a9ec91'), 'src/pshinter/pshalgo.c': (420, 'f169fc3459df53ec5cda2c6f1e7d0f3c2833df3e'), 'src/pshinter/pshalgo.h': (420, '95d41b49aaf0ce857c426085dc47a8739ce18e71'), 'src/pshinter/pshglob.c': (420, '2e4efea068cec06553942064149229160db1ae7f'), 'src/pshinter/pshglob.h': (420, '0158b92ab9deba9e220354706b8af03e3df39f4a'), 'src/pshinter/pshinter.c': (420, 'f22de34bd4a126db749e26d36bd7074626faafbc'), 'src/pshinter/pshmod.c': (420, 'f6b2e2df94c0e44d2c5ce1e7c22ea3c9e08430fd'), 'src/pshinter/pshmod.h': (420, 'd68ef9a87369f7c23ed5e09987ecae209a6b0ee9'), 'src/pshinter/pshnterr.h': (420, '96bc3a31756f2af57021740100692c94008a9b53'), 'src/pshinter/pshrec.c': (420, 'f14c9c7cbda1ba5891f19a86b3784ce22ae8bcbd'), 'src/pshinter/pshrec.h': (420, '0b644f5b964488124923235c953b1d6560fe2463'), 'src/pshinter/rules.mk': (420, '7a3b8f5e33b817c2f5ea41f93610bc10aaf402d4'), 'src/psnames/module.mk': (420, 'bcda0067c820d7b42d32e125799a3a7f9a5990b5'), 'src/psnames/psmodule.c': (420, '5409c61fafab4845ede55fc2995d8db4a10d058d'), 'src/psnames/psmodule.h': (420, '7a619d83fb39b1614363da7d478f17fac9509fe3'), 'src/psnames/psnamerr.h': (420, 'bef9e797c8067446cf3e5db5ef9d56c40f6642bd'), 'src/psnames/psnames.c': (420, 'b0ade9874da6d9e5db3fa60c1a7f6b69298a4232'), 'src/psnames/pstables.h': (420, '8a32aac325f29aa765a39b53125689c8d07c6bb5'), 'src/psnames/rules.mk': (420, '7b0f1d6b47f42e7ceb1c4b3c59d0bbc33371fb1e'), 'src/raster/ftmisc.h': (420, 'cf96cd09ed5f1149ab5bc609a50f3ab8154f813d'), 'src/raster/ftraster.c': (420, 'e0121f6ee1acd0591dc292f3fcba364cec5d0028'), 'src/raster/ftraster.h': (420, 'e20184ddc8eaf4c72ce4b1e33372fdeb1c728b3d'), 'src/raster/ftrend1.c': (420, '6b28cb0bf8d8f4d12a3015859e1decd34ca86b6e'), 'src/raster/ftrend1.h': (420, '92249a0cb9f6c212f45f9b407f9a67a88a99076c'), 'src/raster/module.mk': (420, '7f7567c07ea0809714cb495bc498bf86a92490b0'), 'src/raster/raster.c': (420, 'df2ec38d42e890e8fb29d406be56f4614448ab1e'), 'src/raster/rasterrs.h': (420, '744d179cd8c2cec94be60496eb37162caaeb50bf'), 'src/raster/rules.mk': (420, '90af6d1852a8d4b6fa91b341221a68a88d77b0bb'), 'src/sdf/ftbsdf.c': (420, 'd70ebbf1732ac95f4f2fc95c7f466d931c9bf4c3'), 'src/sdf/ftsdf.c': (420, 'd9d43fcc41c1d487660d3d707d469a954bea5aeb'), 'src/sdf/ftsdf.h': (420, '9bf17d1d9116b0b3b7c612221520ae74877d4eb4'), 'src/sdf/ftsdfcommon.c': (420, 'ffbf7a46a4a300467afb2de82f80947c1620c631'), 'src/sdf/ftsdfcommon.h': (420, 'd62e00fa393cf311c50b1143ab652b6d0b981339'), 'src/sdf/ftsdferrs.h': (420, '5bb8f05bbe2ac3b3eef1e40560b8ce2b35eef9c4'), 'src/sdf/ftsdfrend.c': (420, '1f50ec447a27728fcd719978e3f57fa7aa07c676'), 'src/sdf/ftsdfrend.h': (420, 'bb362949af670f58d2541256dd64c386187222fc'), 'src/sdf/module.mk': (420, 'd8d0d49f6f998c440dba8d0292a0c2516c068624'), 'src/sdf/rules.mk': (420, '92ed750664f0499bf9519a054a313243d8b4a1b3'), 'src/sdf/sdf.c': (420, '21dfe6650b42afa466704893d688185096002a60'), 'src/sfnt/module.mk': (420, '5ed9ce0aa84c80a0a6487f2c5fe90b81f85bea2d'), 'src/sfnt/pngshim.c': (420, 'e588e6b380b449d5acd513a61a99bdcbde4eef54'), 'src/sfnt/pngshim.h': (420, 'f187b639a113431d8d4f602bde2479f7fba6d047'), 'src/sfnt/rules.mk': (420, '791d329a0941a55f6ce45bd7c45d86eb5480c138'), 'src/sfnt/sfdriver.c': (420, '4046b1a0cdbca7e32d4fbd1540d0c8858a73f8a2'), 'src/sfnt/sfdriver.h': (420, 'e9eed184b7fd52f7599bfbd3a55aeb6963fac33e'), 'src/sfnt/sferrors.h': (420, '05b259c1bfcb87397289867fc554de054b689714'), 'src/sfnt/sfnt.c': (420, '2eab87f2fd3a8c078dc3c2bf434ae40cdeb7a251'), 'src/sfnt/sfobjs.c': (420, 'b894331935a80e538345fcc9c7f36e49f6ef1a05'), 'src/sfnt/sfobjs.h': (420, 'a27ad7064acc5507cd696780db8a37cb034ce721'), 'src/sfnt/sfwoff.c': (420, '02125e3cba5d86d85107c8817a02c5d16dc62fbb'), 'src/sfnt/sfwoff.h': (420, 'a563fcc682aee14df26681191724c7ecb22e2b40'), 'src/sfnt/sfwoff2.c': (420, '013e30fc520baeb748f91f78bbc57ce5c144541f'), 'src/sfnt/sfwoff2.h': (420, 'e0296d82603e15afcf444368ab9e9001a26f0a5c'), 'src/sfnt/ttbdf.c': (420, 'e4ece461369177ff45a9bfcead110170a7141863'), 'src/sfnt/ttbdf.h': (420, '87d210e52f795093a85ae5ae311809f65b8d7a47'), 'src/sfnt/ttcmap.c': (420, '6fae7041b8ef6da32fdc8d28e996d3f84d59c1ab'), 'src/sfnt/ttcmap.h': (420, '4b8cbb3197a1cc338d597cabab9f5252cd9b6e30'), 'src/sfnt/ttcmapc.h': (420, 'a704690dae6fce800e7ab176da2048d9afbe3286'), 'src/sfnt/ttcolr.c': (420, '2272ec3739a236873cc3fe3a3cd89dc6fe9547b9'), 'src/sfnt/ttcolr.h': (420, 'c7bf1f2a4a78bbf9855158e19ceeb65b7a94fd92'), 'src/sfnt/ttcpal.c': (420, '04e2db1eab587195729a25254006fe024a6faa6c'), 'src/sfnt/ttcpal.h': (420, '5c2e660e13dc0099d19c87963e2d62b7408cf991'), 'src/sfnt/ttgpos.c': (420, '6f9bddf34ad2fddf4d7f765c2bf7e14a16096758'), 'src/sfnt/ttgpos.h': (420, '3c227445baca2a983376ec40c5e028abf6c6baf8'), 'src/sfnt/ttkern.c': (420, '65b249ff4cdb72e23c1d8d7c06b8f9f6293f86e6'), 'src/sfnt/ttkern.h': (420, '8cc912a79e53acf03c88a0175eecdb6aabce52f8'), 'src/sfnt/ttload.c': (420, '74d319e01f17690dd06f67fdf2cd0e94361a004a'), 'src/sfnt/ttload.h': (420, '0a0aab24ce6c0848d5ff39aca451ac37c683a79e'), 'src/sfnt/ttmtx.c': (420, 'e52df3f583e07825c796ca74901acb9a0c2acfe0'), 'src/sfnt/ttmtx.h': (420, '618e04ffd29d8ac820d6b22370b333efa96f856d'), 'src/sfnt/ttpost.c': (420, '0e0bd0fd366d5da967af5a9896187553bf3d3cc1'), 'src/sfnt/ttpost.h': (420, '896118015e1351d00eae462e2583180d3c9c022f'), 'src/sfnt/ttsbit.c': (420, 'd479b6a0b78ea0eb11676457db51c592a5b83aed'), 'src/sfnt/ttsbit.h': (420, '8fd45223264057600ce2c83fedc4f326476f630d'), 'src/sfnt/ttsvg.c': (420, '79cf531d054aee43fb42172f286b50e858470cb5'), 'src/sfnt/ttsvg.h': (420, '6253ed1d499494959515719a4f42c89b4016f6e9'), 'src/sfnt/woff2tags.c': (420, '1c3779d9f34cf1b4afc7c91e388f0bc273b1f47b'), 'src/sfnt/woff2tags.h': (420, '200262d38639f30f4bc5930a3ffacd9ef5967487'), 'src/smooth/ftgrays.c': (420, '69805f08a270e1c30a3d1616ccffb300b5e5fd52'), 'src/smooth/ftgrays.h': (420, '99c7383e76e82b400991d563dafe71f225ee34a4'), 'src/smooth/ftsmerrs.h': (420, '2f2276bd58c8e37a189b65dc5243a77a7c8e6794'), 'src/smooth/ftsmooth.c': (420, 'f5a3de65d801aa5be5b3de2f6835481c2462e691'), 'src/smooth/ftsmooth.h': (420, '56c7ac70b5c90f9391108ee3b08155fde1dbcff5'), 'src/smooth/module.mk': (420, 'f09f29423c85c469891275fe1890daf498105fbf'), 'src/smooth/rules.mk': (420, '1cdda6d8397682db7bccf116a04fdd8ec763e48d'), 'src/smooth/smooth.c': (420, '4ecd3ccdb9cf45b17c42abe43556716f5f60d302'), 'src/svg/ftsvg.c': (420, 'c98d7f7db90dd99fc8a6f2fa28f00e6b34dd92ef'), 'src/svg/ftsvg.h': (420, '6254485c5a50f4337725d203b2d8652f1fe6295c'), 'src/svg/module.mk': (420, '5a93e174367c9e2d50d7e5a36ff8fe3ee76ec775'), 'src/svg/rules.mk': (420, '53f4629f8cbf3bc5ba48dcea59c407e4295de478'), 'src/svg/svg.c': (420, 'fff03ee59e8a39083a641ae78bae24f776c6d938'), 'src/svg/svgtypes.h': (420, 'f731bdf111267511938ee0b27ac915388f005ffc'), 'src/tools/afblue.pl': (420, '24d01cd1ff5b9bbe4fc66193054c37c171096934'), 'src/tools/apinames.c': (420, '2aa4b9a215b161a332f5ce3be56c7edcc350a273'), 'src/tools/chktrcmp.py': (493, 'd072a87866cba70028fa37a018b2085ecf10ae39'), 'src/tools/cordic.py': (420, '6511429889744ab0ad823ef480c27a723b4ff25b'), 'src/tools/ftrandom/Makefile': (420, '24dc49c563961522b068c37a31bbb81bcf70eac1'), 'src/tools/ftrandom/README': (420, '7c610864b6adbf630677227bca5f5eb13214e6d0'), 'src/tools/ftrandom/ftrandom.c': (420, '0ee765e528face9ecd75c70944874f517c7def8f'), 'src/tools/glnames.py': (420, '9dc28dbc86154bb35f45c6f28134d0e20f463ba6'), 'src/tools/make_distribution_archives.py': (493, 'f29eb128c7a3585bf3846901a9cc6570a0508683'), 'src/tools/no-copyright': (420, 'e171b76f3a79d29d12b3d49c12d75cceb2179759'), 'src/tools/test_afm.c': (420, 'a4b2268984ece21c56a1a909b202024af5493655'), 'src/tools/test_bbox.c': (420, 'd9fd932993d152fcba10e3b615b1c66a2947ec6c'), 'src/tools/test_trig.c': (420, '4f3410ab388400e82a284bf02021a2d8115cdc2d'), 'src/tools/update-copyright': (493, '674823ceb21a2923fad5aa157a7b7f2de058eddd'), 'src/tools/update-copyright-year': (493, '2b19d01fa1fb5c97c7121c45998c5dc60206bef3'), 'src/tools/vms_shorten_symbol.c': (420, '81f2a71877fdeef7a0c7d3c1f8efbd314706f0b9'), 'src/truetype/module.mk': (420, 'e4627b669111e31c7e0cf6991fa0f8a3d08147c0'), 'src/truetype/rules.mk': (420, 'c8b5611b6ef2f0a6c1bd6ff10a4de97607e14dbc'), 'src/truetype/truetype.c': (420, '631f004cb3da3b1d35da9e719789060c752645e4'), 'src/truetype/ttdriver.c': (420, 'b9530b518bcd2bc7007a0b37e1a2c37a5d7ce484'), 'src/truetype/ttdriver.h': (420, 'c00bba066e30f8d84e24ffdef6761125a341793e'), 'src/truetype/tterrors.h': (420, '1ae4b087ac8ecbc5645f76242698a98018a13932'), 'src/truetype/ttgload.c': (420, 'f665361646dda40ec264e711a463758ab8cbd228'), 'src/truetype/ttgload.h': (420, '3d6a762d1f7fe29564b8cb8a1c5fc61ae50bd672'), 'src/truetype/ttgxvar.c': (420, 'd3f8c30fa06ccb88effa20ea2ffc534d182908c3'), 'src/truetype/ttgxvar.h': (420, 'c8446e134b2882ae6706f3ca71fc43cd4413f547'), 'src/truetype/ttinterp.c': (420, 'cc99b2ebd42ef5c98ffb068dc58cf9790e9cfe4d'), 'src/truetype/ttinterp.h': (420, '5b71bb82d8053e69c0c2e095a4727d80e00eb1f0'), 'src/truetype/ttobjs.c': (420, '8c76e23dbf812363b8a5e5d7bfbbe3d0bb212546'), 'src/truetype/ttobjs.h': (420, '01e581e1c1a1412debbaa5b5380e5398008d2e3b'), 'src/truetype/ttpload.c': (420, 'ec85f48ce2c2ebe0765094dc8d24ec20bedf0d18'), 'src/truetype/ttpload.h': (420, 'ad0a9eb7a6d5dc440e1274cd7a4eaf266ca39511'), 'src/truetype/ttvarc.c': (420, 'de57443ced65e5395d2f76643481824422c0e1bc'), 'src/truetype/ttvarc.h': (420, '1ac742a396208bdbabf269c30c6a35a25857e922'), 'src/type1/module.mk': (420, 'a0aeada3ebb29693ac3edac7e99bf0c0c2a4a03e'), 'src/type1/rules.mk': (420, '5d9c2e7e4f3460eb155bffe024daafb3ccf2cb67'), 'src/type1/t1afm.c': (420, 'cc94a0d4a4567f3e73bb95740fe03fa2eaa278cd'), 'src/type1/t1afm.h': (420, 'f31c9d100f0acb1e44e5fc1550ebfb35d74bbc2b'), 'src/type1/t1driver.c': (420, '1d7a342708dd78983a7ca1d67c84d5a9de2bcb95'), 'src/type1/t1driver.h': (420, '2869adab6e747e371177ade81a7c92b5618fbe61'), 'src/type1/t1errors.h': (420, 'efe53be1f4cdb4ccb8c705c03ce47d0d522d04be'), 'src/type1/t1gload.c': (420, 'dd9b6cd80fc2e2f6634dad71760a43f518ad8522'), 'src/type1/t1gload.h': (420, 'b3de427a2f3d283b094c6d44b63e9c450beec448'), 'src/type1/t1load.c': (420, '2ed327ba2e75b0ddd4e62597c4de0249ea17b6fe'), 'src/type1/t1load.h': (420, '39d4b94e9dc8ac8eede58a5a50e8ab47d05333ee'), 'src/type1/t1objs.c': (420, '4ee0a591096b6c79f65ff502e78121a4af147574'), 'src/type1/t1objs.h': (420, 'f152f630a86ec773cfb305d2505f9d92af10b249'), 'src/type1/t1parse.c': (420, '73bfb0cdecce6870f1192c344eea918544f05ab3'), 'src/type1/t1parse.h': (420, 'ebd7c3fb34047e7322bcc400cb4b292f9b408f54'), 'src/type1/t1tokens.h': (420, '745351a34c9540900be09df00e9fada02474d7bc'), 'src/type1/type1.c': (420, 'b8e88e6eac5ee1e3ac9f2e78a7c101d27d794fe6'), 'src/type42/module.mk': (420, 'd87f3a404e5d7bbb1d055198308b834a0e5270a5'), 'src/type42/rules.mk': (420, '3c796cee85f04e3ef757376f0d114568319d34ca'), 'src/type42/t42drivr.c': (420, 'a45d13ebd189f979a2e435d93863b9896b3f5b5c'), 'src/type42/t42drivr.h': (420, '1c2bb2029afe3d724da13b0ee945c4ddceda9016'), 'src/type42/t42error.h': (420, '9c386d8c48f8de240d3f3c95eafca1b8c55b3303'), 'src/type42/t42objs.c': (420, 'a01c3129d07b2fcc977c7323de578f624a193469'), 'src/type42/t42objs.h': (420, '15767f871634c2eb75010ef2f1005fcd347c758a'), 'src/type42/t42parse.c': (420, 'd645be2a01467142fdac8336d20e16e4801111db'), 'src/type42/t42parse.h': (420, '4e61169a8710868782cb565404c0e2d7e8d37051'), 'src/type42/t42types.h': (420, 'b0bf9e8ecfed4eeeb7d146fef858ad8a73fd000c'), 'src/type42/type42.c': (420, 'da1e6214d32bdbde951bee10e381c9f42c75c698'), 'src/winfonts/fnterrs.h': (420, 'b2644edbf3a35c99115724b8b6515660ffe5ab53'), 'src/winfonts/module.mk': (420, 'd49dc9d3b2ab93cdc3941dbb2cae466cdd76f8c5'), 'src/winfonts/rules.mk': (420, 'b65bb4c41af9ccd4a25e538a693c9e23c80aef49'), 'src/winfonts/winfnt.c': (420, '99f31f61f7b63389c8d4e9c61d5cbf4ea5fa56fa'), 'src/winfonts/winfnt.h': (420, '420e11e3c6709418c7a582bf59c423b29f888b7f'), 'subprojects/harfbuzz.wrap': (420, '3ef970046cb348c170d5346cda75faeaa81753cc'), 'subprojects/libpng.wrap': (420, '7bc11fc0fa9abf5fcbc6317b18bf18b888b14f3f'), 'subprojects/zlib.wrap': (420, '0626401ac2559b541b45ac90eb184ad0c2c6b10e'), 'tests/README.md': (420, '13d1e6cb8fb840c0420fcd744fb77373ec54fab7'), 'tests/data/varc-null-condition.ttf': (420, 'c68f5c922d4de32929b468a102159b60dfa6fd24'), 'tests/data/varc-reset-only.ttf': (420, '19cbb5bbf82e50437c4420f9ea2ec78d05e95153'), 'tests/data/varc-short-cff2.otf': (420, 'ffd46414a384406f7e67817cd9bb76eec5c92041'), 'tests/data/varc-static-cff2.otf': (420, '577396e9cf9c987098d9ca677b0bfa88b31130a9'), 'tests/data/varc-static-gvar.ttf': (420, '649c2961c766bfd92c2a32e17c5b9b66649ba51a'), 'tests/data/varc-value-conditions.ttf': (420, 'dcef465a6d1538c9f628fdf50c11bb7b4cde9780'), 'tests/data/varc-variation-store.ttf': (420, 'd403410e488ee365929033b310894dff96241e3a'), 'tests/issue-1063/main.c': (420, '3d59da7b4d49ef381ce383a0c0cdc7810ad942ee'), 'tests/issue-1441/README.md': (420, '74dafeaabe020c4663812bddda189b903e8e540f'), 'tests/issue-1441/main.c': (420, 'dd7e20b94780c407c534c2fc3b0890d9b16bf612'), 'tests/issue-1441/make-fonts.py': (420, 'd8ede9063f6fe5e95cc20a474093169f5bb1029f'), 'tests/issue-1469/README.md': (420, 'd9c013dbf2c7fa06e56fb5ead69d3a8708ecb492'), 'tests/issue-1469/main.c': (420, 'b67c023375d8922fd5910e23a860b300cb1039db'), 'tests/issue-1469/make-fonts.py': (420, 'e0bea4ed3406eceec937401a0e06d29546e6789e'), 'tests/meson.build': (420, '4448bb1e2ab01aeb20a8b62fbbc6100bd9e6584a'), 'tests/outline-reverse/main.c': (420, '8f292c6e5b4121c1d18cd828d0c7af9c2861f0d2'), 'tests/scripts/download-test-fonts.py': (493, '52b742e22ca616899adc32ddc3308906cb5a8c4d'), 'tests/varc/main.c': (420, '6981f498add1b8b4f443129128e54d4b24d8d5a7'), 'vms_make.com': (420, '75bcbd7abf51f95b15c96b55a4ca392d9aa8a2bc')}
FREETYPE_GIT_DIRS = frozenset(['builds', 'builds/amiga', 'builds/amiga/include', 'builds/amiga/include/config', 'builds/amiga/src', 'builds/amiga/src/base', 'builds/ansi', 'builds/atari', 'builds/beos', 'builds/cmake', 'builds/compiler', 'builds/dos', 'builds/mac', 'builds/meson', 'builds/os2', 'builds/plan9', 'builds/symbian', 'builds/unix', 'builds/vms', 'builds/wince', 'builds/wince/vc2005-ce', 'builds/wince/vc2008-ce', 'builds/windows', 'builds/windows/vc2010', 'builds/windows/visualc', 'builds/windows/visualce', 'devel', 'docs', 'docs/markdown', 'docs/markdown/images', 'docs/markdown/javascripts', 'docs/markdown/stylesheets', 'docs/oldlogs', 'include', 'include/freetype', 'include/freetype/config', 'include/freetype/internal', 'include/freetype/internal/services', 'objs', 'src', 'src/autofit', 'src/base', 'src/bdf', 'src/bzip2', 'src/cache', 'src/cff', 'src/cid', 'src/dlg', 'src/gxvalid', 'src/gzip', 'src/gzip/patches', 'src/hvf', 'src/lzw', 'src/otvalid', 'src/pcf', 'src/pfr', 'src/psaux', 'src/pshinter', 'src/psnames', 'src/raster', 'src/sdf', 'src/sfnt', 'src/smooth', 'src/svg', 'src/tools', 'src/tools/ftrandom', 'src/truetype', 'src/type1', 'src/type42', 'src/winfonts', 'subprojects', 'tests', 'tests/data', 'tests/issue-1063', 'tests/issue-1441', 'tests/issue-1469', 'tests/outline-reverse', 'tests/scripts', 'tests/varc', '', 'subprojects/dlg'])

SUBTITLE_CAPTURE_TAR_OUTPUT = 'apple-subtitle-release-sources.tar'
SUBTITLE_CAPTURE_RECEIPT_OUTPUT = 'apple-subtitle-release-sources.json'
SUBTITLE_BUILD_OUTPUT = 'apple-subtitle-builds.json'
SUBTITLE_INSTALLED_HELPERS = {
    'Sources/BuildScripts/subtitle-release-sources.py':
        'd09496535e49241575093692846de60b9e5948819d6540c4002047d12b5d37f3',
}
SUBTITLE_MATRIX = (
    ('ios', 'arm64', 'ios-arm64'),
    ('isimulator', 'arm64', 'ios-arm64_x86_64-simulator'),
    ('isimulator', 'x86_64', 'ios-arm64_x86_64-simulator'),
    ('tvos', 'arm64', 'tvos-arm64_arm64e'),
    ('tvos', 'arm64e', 'tvos-arm64_arm64e'),
    ('tvsimulator', 'arm64', 'tvos-arm64_x86_64-simulator'),
    ('tvsimulator', 'x86_64', 'tvos-arm64_x86_64-simulator'),
    ('macos', 'arm64', 'macos-arm64_x86_64'),
    ('macos', 'x86_64', 'macos-arm64_x86_64'),
)
SUBTITLE_VERSIONS = {'libunibreak': '8.0', 'libfribidi': '1.0.17',
                     'libharfbuzz': '15.0.0', 'libbluray': '1.5.0'}
SUBTITLE_SELECTORS = {'libunibreak': '8.0-9c4fad6e',
                      'libfribidi': '1.0.17-6949dcde',
                      'libharfbuzz': '15.0.0-968536e9', 'libbluray': '1.5.0-f676408e'}
SUBTITLE_ROUTES = {'libunibreak': 'release-autoconf',
                   'libfribidi': 'release-meson',
                   'libharfbuzz': 'release-meson', 'libbluray': 'release-meson'}
SUBTITLE_ARGUMENTS = {
    'libbluray': ('--wrap-mode=nodownload', '--force-fallback-for=libudfread',
                   '-Denable_docs=false', '-Denable_tools=false', '-Denable_devtools=false',
                   '-Denable_examples=false', '-Dbdj_jar=disabled', '-Dembed_udfread=true',
                   '-Dfontconfig=disabled', '-Dfreetype=enabled', '-Dlibxml2=enabled'),
    'libunibreak': None,
    'libfribidi': ('--wrap-mode=nodownload', '-Dtests=false', '-Ddocs=false',
                   '-Dbin=false', '-Ddeprecated=true'),
    'libharfbuzz': ('--wrap-mode=nodownload', '-Dauto_features=disabled',
                    '-Dtests=disabled', '-Ddocs=disabled', '-Dutilities=disabled',
                    '-Dintrospection=disabled', '-Dfreetype=disabled',
                    '-Dcoretext=disabled', '-Dglib=disabled', '-Dgobject=disabled',
                    '-Dcairo=disabled', '-Dchafa=disabled', '-Dpng=disabled',
                    '-Dzlib=disabled', '-Dicu=disabled', '-Dgraphite2=disabled',
                    '-Dfontations=disabled', '-Dharfrust=disabled', '-Dkbts=disabled',
                    '-Dwasm=disabled', '-Dgpu_demo=disabled', '-Dbenchmark=disabled',
                    '-Draster=disabled', '-Dvector=disabled', '-Dgpu=disabled',
                    '-Dsubset=disabled'),
}
SUBTITLE_MAKE_ARGUMENTS = ('-j1', 'AUTOCONF=/usr/bin/false',
                           'AUTOHEADER=/usr/bin/false', 'AUTOMAKE=/usr/bin/false',
                           'ACLOCAL=/usr/bin/false')
SUBTITLE_GENERATED = {
    'libbluray': ('crossFile.meson', 'build.ninja', 'compile_commands.json',
                  'meson-info/intro-buildoptions.json', 'meson-info/intro-dependencies.json',
                  'config.h', 'contrib/libudfread/config.h'),
    'libunibreak': ('Makefile', 'config.status', 'config.log'),
    'libfribidi': ('crossFile.meson', 'build.ninja', 'compile_commands.json',
                   'meson-info/intro-buildoptions.json',
                   'meson-info/intro-dependencies.json'),
    'libharfbuzz': ('crossFile.meson', 'build.ninja', 'compile_commands.json',
                    'meson-info/intro-buildoptions.json',
                    'meson-info/intro-dependencies.json'),
}
SUBTITLE_INSTALLED = {
    'libbluray': ('include/libbluray/bluray-version.h', 'lib/pkgconfig/libbluray.pc'),
    'libunibreak': ('include/unibreakbase.h', 'lib/pkgconfig/libunibreak.pc'),
    'libfribidi': ('include/fribidi/fribidi-config.h', 'lib/pkgconfig/fribidi.pc'),
    'libharfbuzz': ('include/harfbuzz/hb-version.h', 'lib/pkgconfig/harfbuzz.pc'),
}
SUBTITLE_VERSIONS['libfreetype'] = '2.15.0'
SUBTITLE_SELECTORS['libfreetype'] = '2.15.0-37515cf5'
SUBTITLE_ROUTES['libfreetype'] = 'release-meson'
SUBTITLE_ARGUMENTS['libfreetype'] = ('--wrap-mode=nodownload', '-Dzlib=system', '-Dharfbuzz=disabled', '-Dbzip2=disabled', '-Dmmap=disabled', '-Dpng=disabled', '-Dbrotli=disabled', '-Dhvf=disabled', '-Dtests=disabled', '-Derror_strings=false')
SUBTITLE_GENERATED['libfreetype'] = ('crossFile.meson', 'build.ninja', 'compile_commands.json', 'meson-info/intro-buildoptions.json', 'meson-info/intro-dependencies.json', 'ftoption.h', 'ftmodule.h', 'vortx-sdk-pkgconfig/zlib.pc')
SUBTITLE_INSTALLED['libfreetype'] = ('include/freetype2/freetype/freetype.h', 'include/freetype2/freetype/config/ftoption.h', 'include/freetype2/freetype/config/ftmodule.h', 'include/freetype2/freetype/config/ftconfig.h', 'lib/pkgconfig/freetype2.pc')

SUBTITLE_MAX_RECORD = 16 * 1024 * 1024
SUBTITLE_MAX_BODY = 8 * 1024 * 1024
SUBTITLE_MAX_RECORD_BODIES = 8 * 1024 * 1024
SUBTITLE_MAX_INLINE_RAW = 32 * 1024 * 1024
SUBTITLE_MAX_RECEIPT = 64 * 1024 * 1024


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


def _bluray_source_body(pin, name, body):
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



def _crypto_canonical(value):
    return (json.dumps(value, sort_keys=True, separators=(',', ':')) + '\n').encode()


def _crypto_identity(info):
    return (info.st_dev, info.st_ino, info.st_size, info.st_mode,
            info.st_mtime_ns, info.st_ctime_ns)


def _crypto_read_regular(path, maximum):
    if not path.is_absolute() or '..' in path.parts:
        raise ValueError('crypto source input must be one absolute path')
    current = Path(path.anchor)
    for part in path.parts[1:]:
        current /= part
        if current.is_symlink():
            raise ValueError('crypto source input has a linked ancestor')
    before = path.lstat()
    if (not stat.S_ISREG(before.st_mode) or before.st_nlink != 1
            or before.st_size < 0 or before.st_size > maximum):
        raise ValueError('crypto source input is not one bounded regular file')
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, 'rb') as stream:
        opened = os.fstat(stream.fileno())
        if _crypto_identity(opened) != _crypto_identity(before):
            raise ValueError('crypto source input changed before reading')
        body = stream.read(maximum + 1)
        if len(body) > maximum or _crypto_identity(os.fstat(stream.fileno())) != _crypto_identity(opened):
            raise ValueError('crypto source input changed or exceeded its bound')
    if _crypto_identity(path.lstat()) != _crypto_identity(before) or len(body) != before.st_size:
        raise ValueError('crypto source input changed during reading')
    return body


def _crypto_member_path(value):
    if (not isinstance(value, str) or not value or len(value.encode('utf-8')) > CRYPTO_MAX_PATH
            or not value.isprintable() or value.startswith('/') or '\\' in value
            or ':' in value or '\x00' in value):
        raise ValueError('unsafe crypto source archive path')
    parts = value.rstrip('/').split('/')
    if any(part in ('', '.', '..') or part.casefold() == '.git' for part in parts):
        raise ValueError('unsafe crypto source archive path component')
    return '/'.join(parts)


def _crypto_link_path(parent, target):
    if (not isinstance(target, str) or not target or len(target.encode('utf-8')) > CRYPTO_MAX_PATH
            or not target.isprintable() or target.startswith('/') or '\\' in target
            or ':' in target or '\x00' in target):
        raise ValueError('unsafe crypto source symlink target')
    parts = list(parent)
    for part in target.split('/'):
        if part in ('', '.'):
            continue
        if part == '..':
            if not parts:
                raise ValueError('crypto source symlink escapes its release root')
            parts.pop()
        elif part.casefold() == '.git':
            raise ValueError('crypto source symlink points through Git metadata')
        else:
            parts.append(part)
    return '/'.join(parts)


def _crypto_mtime(value):
    if type(value) is not int or not 0 <= value <= CRYPTO_MAX_MTIME:
        raise ValueError('crypto source mtime must be bounded integral seconds')
    return value


def _crypto_archive_mtime_ns(member):
    """Recover exact archive nanoseconds without trusting TarInfo's float view."""
    if type(member.pax_headers) is not dict:
        raise ValueError('subtitle source PAX metadata must be a dictionary')
    if 'mtime' in member.pax_headers:
        raw = member.pax_headers['mtime']
        if (type(raw) is not str or len(raw) > 32
                or re.fullmatch(r'[0-9]{1,10}(?:\.[0-9]{1,9})?', raw) is None):
            raise ValueError('subtitle source PAX mtime must be bounded decimal text')
        seconds, separator, fraction = raw.partition('.')
        value = int(seconds) * 1000000000
        if separator:
            value += int(fraction.ljust(9, '0'))
    else:
        if type(member.mtime) is not int:
            raise ValueError('subtitle source float-only mtime is not admitted')
        value = member.mtime * 1000000000
    if type(value) is not int or not 0 <= value <= CRYPTO_MAX_MTIME_NS:
        raise ValueError('subtitle source mtimeNs must be bounded integral nanoseconds')
    return value


def _crypto_member_mtime(member, nanoseconds):
    return _crypto_archive_mtime_ns(member) if nanoseconds else _crypto_mtime(member.mtime)


class _CryptoLimitedReader:
    def __init__(self, stream, maximum):
        self.stream, self.maximum, self.count = stream, maximum, 0

    def read(self, size=-1):
        allowance = self.maximum - self.count
        if size < 0 or size > allowance + 1:
            size = allowance + 1
        block = self.stream.read(size)
        self.count += len(block)
        if self.count > self.maximum:
            raise ValueError('crypto source archive exceeds its expanded bound')
        return block


def _crypto_tar_stream(blob, compression):
    raw = io.BytesIO(blob)
    if compression == 'xz':
        decoded = lzma.LZMAFile(raw, 'rb')
    elif compression == 'gz':
        decoded = gzip.GzipFile(fileobj=raw, mode='rb')
    elif compression == 'none':
        decoded = raw
    else:
        raise ValueError('unknown fixed crypto source compression')
    return tarfile.open(fileobj=_CryptoLimitedReader(decoded, CRYPTO_MAX_UNCOMPRESSED), mode='r|')


def _crypto_file_row(member, stream, nanoseconds=False):
    if member.size < 0 or member.size > CRYPTO_MAX_MEMBER:
        raise ValueError('crypto source member exceeds its bound')
    hasher, count = hashlib.sha256(), 0
    while True:
        block = stream.read(min(1024 * 1024, member.size - count + 1))
        if not block:
            break
        count += len(block)
        if count > member.size:
            raise ValueError('crypto source member exceeds its declared length')
        hasher.update(block)
    if count != member.size:
        raise ValueError('truncated crypto source member')
    return {'kind': 'file', 'mode': 0o755 if member.mode & 0o111 else 0o644,
            ('mtimeNs' if nanoseconds else 'mtime'):
                _crypto_member_mtime(member, nanoseconds),
            'bytes': count, 'sha256': hasher.hexdigest()}


def _crypto_finish_index(entries, nanoseconds=False):
    time_key = 'mtimeNs' if nanoseconds else 'mtime'
    for name in list(entries):
        parts = name.split('/') if name else []
        for end in range(1, len(parts)):
            parent = '/'.join(parts[:end])
            row = entries.setdefault(parent, {'kind': 'directory', 'mode': 0o755,
                                               time_key: 0})
            if row['kind'] != 'directory':
                raise ValueError('crypto source non-directory member has children')
            if len(entries) > CRYPTO_MAX_MEMBERS:
                raise ValueError('crypto source archive has too many paths')
    folded = {}
    for name in entries:
        key = name.casefold()
        if key in folded and folded[key] != name:
            raise ValueError('crypto source archive has case-colliding members')
        folded[key] = name

    def resolve(name, visited=()):
        if len(visited) >= 32:
            raise ValueError('crypto source symlink chain exceeds its bound')
        parts = name.split('/') if name else []
        for end in range(1, len(parts) + 1):
            prefix = '/'.join(parts[:end])
            row = entries.get(prefix)
            if row is None:
                raise ValueError('dangling crypto source symlink')
            if row['kind'] == 'symlink':
                if prefix in visited:
                    raise ValueError('cyclic crypto source symlink')
                destination = _crypto_link_path(parts[:end - 1], row['target'])
                tail = parts[end:]
                following = '/'.join(([destination] if destination else []) + tail)
                return resolve(following, visited + (prefix,))
            if end < len(parts) and row['kind'] != 'directory':
                raise ValueError('crypto source symlink resolves through a non-directory')
        return name

    for name, row in entries.items():
        if row['kind'] == 'symlink':
            resolve(name)
    return [{'path': name, **entries[name]} for name in sorted(entries)]



def _freetype_source_row(member, stream, name):
    wanted = FREETYPE_GIT_FILES.get(name)
    if wanted is None or not 0 <= member.size <= CRYPTO_MAX_MEMBER:
        raise ValueError('FreeType undeclared/oversized source Git blob')
    data = stream.read(CRYPTO_MAX_MEMBER + 1)
    mode = 0o755 if member.mode & 0o111 else 0o644
    if len(data) != member.size or mode != wanted[0] or hashlib.sha1(b'blob ' + str(len(data)).encode() + b'\0' + data).hexdigest() != wanted[1]:
        raise ValueError('FreeType source bytes/executable mode differ from official Git membership')
    return {'kind': 'file', 'mode': mode, 'mtimeNs': _crypto_archive_mtime_ns(member), 'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest()}


def _freetype_source_members(rows):
    if ({r['path'] for r in rows if r['kind'] == 'file'} != set(FREETYPE_GIT_FILES)
            or any(r['kind'] not in ('file', 'directory') or (r['kind'] == 'directory' and r['path'] not in FREETYPE_GIT_DIRS) for r in rows)
            or any(r['path'].startswith('subprojects/dlg/') for r in rows)):
        raise ValueError('FreeType complete source family/empty dlg gitlink differs')

def _crypto_index_archive(pin, blob, nanoseconds=False):
    maximum_archive = min(CRYPTO_MAX_UNCOMPRESSED,
                          pin.get('maximumBytes', CRYPTO_MAX_ARCHIVE))
    if (len(blob) > maximum_archive
            or (pin['bytes'] is not None and len(blob) != pin['bytes'])
            or hashlib.sha256(blob).hexdigest() != pin['sha256']):
        raise ValueError('crypto release source body differs from its fixed pin')
    time_key = 'mtimeNs' if nanoseconds else 'mtime'
    entries = {'': {'kind': 'directory', 'mode': 0o755, time_key: 0}}
    seen, total, transformed = set(), 0, set()
    with _crypto_tar_stream(blob, pin['compression']) as archive:
        for member in archive:
            if len(seen) >= CRYPTO_MAX_MEMBERS:
                raise ValueError('crypto source archive has too many members')
            full = _crypto_member_path(member.name)
            root, separator, name = full.partition('/')
            if root != pin['archiveRoot']:
                raise ValueError('crypto source archive has a foreign top-level root')
            if full.casefold() in seen:
                raise ValueError('duplicate or case-colliding crypto source member')
            seen.add(full.casefold())
            if getattr(member, 'sparse', None) or any('sparse' in key.casefold() for key in member.pax_headers):
                raise ValueError('sparse crypto source members are not admitted')
            if not separator:
                if not member.isdir():
                    raise ValueError('crypto source archive root is not a directory')
                entries[''][time_key] = _crypto_member_mtime(member, nanoseconds)
                continue
            if member.isdir():
                row = {'kind': 'directory', 'mode': 0o755,
                       time_key: _crypto_member_mtime(member, nanoseconds)}
            elif member.isreg():
                total += member.size
                if total > CRYPTO_MAX_UNCOMPRESSED:
                    raise ValueError('crypto source member total exceeds its bound')
                stream = archive.extractfile(member)
                if stream is None:
                    raise ValueError('missing crypto source member body')
                with stream:
                    if pin['id'] == 'libfreetype':
                        row = _freetype_source_row(member, stream, name)
                    elif pin['id'] == 'libbluray' and name in BLURAY_SOURCE_TRANSFORMS:
                        raw = stream.read(CRYPTO_MAX_MEMBER + 1)
                        if len(raw) != member.size or len(raw) > CRYPTO_MAX_MEMBER:
                            raise ValueError('libbluray raw source member length differs')
                        data = _bluray_source_body(pin, name, raw)
                        transformed.add(name)
                        row = {'kind': 'file', 'mode': 0o755 if member.mode & 0o111 else 0o644,
                               time_key: _crypto_member_mtime(member, nanoseconds),
                               'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest()}
                    else:
                        row = _crypto_file_row(member, stream, nanoseconds)
            elif member.issym():
                _crypto_link_path(name.split('/')[:-1], member.linkname)
                body = member.linkname.encode('utf-8')
                row = {'kind': 'symlink', 'mode': 0o777, 'bytes': len(body),
                       time_key: _crypto_member_mtime(member, nanoseconds),
                       'sha256': hashlib.sha256(body).hexdigest(), 'target': member.linkname}
            else:
                raise ValueError('crypto source hardlinks and special members are not admitted')
            if name in entries:
                raise ValueError('duplicate crypto source member')
            entries[name] = row
    if pin['id'] == 'libbluray' and transformed != set(BLURAY_SOURCE_TRANSFORMS):
        raise ValueError('libbluray fixed source transform members are incomplete')
    rows = _crypto_finish_index(entries, nanoseconds)
    if pin["id"] == "libfreetype":
        _freetype_source_members(rows)
    entry_point = pin.get('entryPoint', 'configure')
    entry = next((row for row in rows if row['path'] == entry_point), None)
    if (entry is None or entry['kind'] != 'file'
            or (entry_point == 'configure' and entry['mode'] != 0o755)):
        raise ValueError('release archive lacks its fixed regular build entry point')
    return rows


def _crypto_expected_receipt(verified, profile=None,
                             identity_basis='fixed-sha256-corroborated-by-package-maintainer-metadata',
                             schema=1):
    if profile is None:
        profile = CRYPTO_SOURCE_PROFILE
    roots = []
    for pin, blob, rows in verified:
        roots.append({
            'id': pin['id'], 'version': pin['version'], 'url': pin['url'],
            'archive': 'archives/' + pin['filename'], 'archiveRoot': pin['archiveRoot'],
            'archiveBytes': len(blob), 'archiveSHA256': pin['sha256'],
            'sourceRoot': 'dist/' + pin['sourceRoot'],
            'membersSHA256': hashlib.sha256(_crypto_canonical(rows)).hexdigest(),
            'members': rows,
            **({'sourceTransformPolicy': pin.get('sourceTransformPolicy', 'none')} if schema == 3 else {}),
        })
    return {'schema': schema, 'profile': profile,
            'identityBasis': identity_basis,
            'upstreamSignatureVerified': False, 'roots': roots}


def _crypto_strict_json(data):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError('duplicate crypto source receipt key')
            result[key] = value
        return result
    return json.loads(data.decode('utf-8', errors='strict'), object_pairs_hook=unique,
                      parse_constant=lambda _: (_ for _ in ()).throw(
                          ValueError('non-finite crypto source receipt number')))


def _crypto_exact_equal(left, right):
    """JSON equality that never aliases booleans with integers."""
    if type(left) is not type(right):
        return False
    if isinstance(left, dict):
        return (set(left) == set(right) and
                all(_crypto_exact_equal(left[key], right[key]) for key in left))
    if isinstance(left, list):
        return (len(left) == len(right) and
                all(_crypto_exact_equal(a, b) for a, b in zip(left, right)))
    return left == right


def _crypto_capture_correspondence(path, expected, member_limit=None,
                                   nanoseconds=False):
    if member_limit is None:
        member_limit = CRYPTO_MAX_MEMBERS * len(CRYPTO_SOURCE_OUTPUTS)
    if not path.is_absolute() or path.is_symlink():
        raise ValueError('captured crypto source tar must be one absolute regular file')
    before = path.lstat()
    if (not stat.S_ISREG(before.st_mode) or before.st_nlink != 1
            or before.st_size < 1 or before.st_size > CRYPTO_MAX_UNCOMPRESSED):
        raise ValueError('captured crypto source tar exceeds its bound')
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    observed, count, folded = set(), 0, set()
    with os.fdopen(descriptor, 'rb') as stream:
        opened = os.fstat(stream.fileno())
        if _crypto_identity(opened) != _crypto_identity(before):
            raise ValueError('captured crypto source tar changed before reading')
        bounded = _CryptoLimitedReader(stream, CRYPTO_MAX_UNCOMPRESSED)
        with tarfile.open(fileobj=bounded, mode='r|') as archive:
            for member in archive:
                name = _crypto_member_path(member.name)
                count += 1
                if (count > member_limit
                        or name in observed or name.casefold() in folded or name not in expected):
                    raise ValueError('captured crypto source tar has an extra or duplicate member')
                observed.add(name)
                folded.add(name.casefold())
                wanted = expected[name]
                time_key = 'mtimeNs' if nanoseconds else 'mtime'
                if member.isdir():
                    actual = {'kind': 'directory', 'mode': member.mode,
                              time_key: _crypto_member_mtime(member, nanoseconds)}
                elif (member.isreg() and member.mode in (0o644, 0o755)
                      and not getattr(member, 'sparse', None)
                      and not any('sparse' in key.casefold() for key in member.pax_headers)):
                    body = archive.extractfile(member)
                    if body is None:
                        raise ValueError('captured crypto source member has no body')
                    with body:
                        actual = _crypto_file_row(member, body, nanoseconds)
                elif member.issym():
                    _crypto_link_path(name.split('/')[:-1], member.linkname)
                    body = member.linkname.encode('utf-8')
                    actual = {'kind': 'symlink', 'mode': 0o777, 'bytes': len(body),
                              time_key: _crypto_member_mtime(member, nanoseconds),
                              'sha256': hashlib.sha256(body).hexdigest(),
                              'target': member.linkname}
                else:
                    raise ValueError('captured crypto source tar has an unsupported member')
                if not _crypto_exact_equal(actual, wanted):
                    raise ValueError('captured crypto source member differs from its raw archive')
        if _crypto_identity(os.fstat(stream.fileno())) != _crypto_identity(opened):
            raise ValueError('captured crypto source tar changed during reading')
    if _crypto_identity(path.lstat()) != _crypto_identity(before) or observed != set(expected):
        raise ValueError('captured crypto source tar changed or omitted release members')


def crypto_source_outputs(output, *, pins=None, profile=None,
                          capture_tar=None, capture_receipt=None,
                          capture_tar_logical='crypto-release-sources.tar',
                          capture_receipt_logical='crypto-release-sources.json',
                          identity_basis='fixed-sha256-corroborated-by-package-maintainer-metadata',
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
                      pin.get('maximumBytes', CRYPTO_MAX_ARCHIVE))
        body = _crypto_read_regular(output / pin['output'], maximum)
        rows = _crypto_index_archive(pin, body, nanoseconds)
        verified.append((pin, body, rows))
        output_rows.append({'logicalPath': 'archives/' + pin['filename'],
                            'name': pin['output'], 'bytes': len(body),
                            'sha256': hashlib.sha256(body).hexdigest()})
    expected_receipt = _crypto_expected_receipt(
        verified, profile, identity_basis, receipt_schema)
    receipt_body = _crypto_read_regular(output / capture_receipt,
                                        CRYPTO_MAX_RECEIPT)
    if (not _crypto_exact_equal(_crypto_strict_json(receipt_body), expected_receipt)
            or receipt_body != _crypto_canonical(expected_receipt)):
        raise ValueError('captured crypto source receipt differs from raw source bodies')
    expected_members = {}
    for pin, _, rows in verified:
        for row in rows:
            name = pin['archiveRoot'] + (('/' + row['path']) if row['path'] else '')
            if name in expected_members:
                raise ValueError('overlapping captured crypto source roots')
            expected_members[name] = {key: value for key, value in row.items() if key != 'path'}
    capture_path = output / capture_tar
    _crypto_capture_correspondence(
        capture_path, expected_members, CRYPTO_MAX_MEMBERS * len(pins), nanoseconds)
    capture_body = _crypto_read_regular(capture_path, CRYPTO_MAX_UNCOMPRESSED)
    receipt_row = {'logicalPath': capture_receipt_logical,
                   'name': capture_receipt, 'bytes': len(receipt_body),
                   'sha256': hashlib.sha256(receipt_body).hexdigest()}
    capture_row = {'logicalPath': capture_tar_logical,
                   'name': capture_tar, 'bytes': len(capture_body),
                   'sha256': hashlib.sha256(capture_body).hexdigest()}
    roots = []
    for root, pin in zip(expected_receipt['roots'], pins, strict=True):
        roots.append({'id': root['id'], 'version': root['version'],
                      'archiveRoot': root['archiveRoot'], 'sourceRoot': root['sourceRoot'],
                      'archive': output_rows[len(roots)],
                      'membersSHA256': root['membersSHA256'],
                      **({'sourceTransformPolicy': root['sourceTransformPolicy']} if receipt_schema == 3 else {})})
    return {'profile': profile, 'roots': roots,
            'capture': {'tar': capture_row, 'receipt': receipt_row}}


def subtitle_source_outputs(output):
    return crypto_source_outputs(
        output, pins=SUBTITLE_SOURCE_OUTPUTS, profile=SUBTITLE_SOURCE_PROFILE,
        capture_tar=SUBTITLE_CAPTURE_TAR_OUTPUT,
        capture_receipt=SUBTITLE_CAPTURE_RECEIPT_OUTPUT,
        capture_tar_logical='subtitle-release-sources.tar',
        capture_receipt_logical='subtitle-release-sources.json',
        identity_basis='fixed-sha256-from-upstream-release-metadata-maintained-android-pin-or-official-sidecar; fixed-apple-source-transforms; official-freetype-git-membership-empty-dlg-v1',
        receipt_schema=3, nanoseconds=True)


def _shaderc_regular(path, label):
    """Require one immutable regular input; never follow an input symlink."""
    if (not path.is_absolute() or path.is_symlink() or not path.is_file()):
        raise ValueError('shaderc ' + label + ' must be an absolute regular file')
    stat_result = path.stat()
    if not stat.S_ISREG(stat_result.st_mode) or stat_result.st_nlink != 1:
        raise ValueError('shaderc ' + label + ' is not an exact regular file')
    return stat_result


def _shaderc_body(path, expected_name, expected_bytes, expected_sha256):
    _shaderc_regular(path, expected_name)
    observed = {'bytes': 0, 'sha256': hashlib.sha256()}
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            observed['bytes'] += len(block)
            if observed['bytes'] > expected_bytes:
                raise ValueError('shaderc input exceeds its pinned byte count: ' + expected_name)
            observed['sha256'].update(block)
    digest_value = observed['sha256'].hexdigest()
    if observed['bytes'] != expected_bytes or digest_value != expected_sha256:
        raise ValueError('shaderc input bytes/hash differ: ' + expected_name)
    return {'name': expected_name, 'bytes': observed['bytes'], 'sha256': digest_value}


def _shaderc_file_sha(path, label):
    """Hash a bounded generated file without accepting a link or special file."""
    _shaderc_regular(path, label)
    size = path.stat().st_size
    if size > SHADERC_MAX_MEMBER:
        raise ValueError('shaderc generated file exceeds bound: ' + label)
    h = hashlib.sha256()
    count = 0
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            count += len(block)
            if count > SHADERC_MAX_MEMBER:
                raise ValueError('shaderc generated file exceeds bound: ' + label)
            h.update(block)
    if count != size:
        raise ValueError('shaderc generated file length changed: ' + label)
    return count, h.hexdigest()


def _shaderc_archive_name(name):
    try:
        encoded = name.encode('utf-8') if isinstance(name, str) else b''
    except UnicodeEncodeError as exc:
        raise ValueError('unsafe shaderc ZIP entry name') from exc
    if (not isinstance(name, str) or not name or len(encoded) > 4096
            or '\x00' in name or '\\' in name or name.startswith('/')
            or not name.isprintable()):
        raise ValueError('unsafe shaderc ZIP entry name')
    pieces = name.rstrip('/').split('/')
    if not pieces or any(piece in ('', '.', '..') for piece in pieces):
        raise ValueError('traversal shaderc ZIP entry name')
    return '/'.join(pieces)


def _shaderc_link_body(archive, info, name):
    """Read and authenticate one bounded ZIP link body; never create a link."""
    if info.file_size > SHADERC_MAX_LINK_BODY:
        raise ValueError('shaderc ZIP symlink body exceeds bound: ' + name)
    with archive.open(info) as stream:
        raw = stream.read(SHADERC_MAX_LINK_BODY + 1)
    if len(raw) != info.file_size or len(raw) > SHADERC_MAX_LINK_BODY:
        raise ValueError('shaderc ZIP symlink body length changed: ' + name)
    try:
        target = raw.decode('utf-8')
    except UnicodeDecodeError as exc:
        raise ValueError('shaderc ZIP symlink body is not UTF-8: ' + name) from exc
    try:
        canonical = _shaderc_archive_name(target)
    except ValueError as exc:
        raise ValueError('unsafe shaderc ZIP symlink target: ' + name) from exc
    if canonical != target:
        raise ValueError('non-canonical shaderc ZIP symlink target: ' + name)
    return target, len(raw), hashlib.sha256(raw).hexdigest()


def _shaderc_within_prefix(name, prefix):
    return name == prefix or name.startswith(prefix + '/')


def _shaderc_link_target(name, target, framework_prefix):
    """Resolve a relative archive link without touching the filesystem."""
    try:
        canonical = _shaderc_archive_name(target)
    except ValueError as exc:
        raise ValueError('unsafe shaderc ZIP symlink target: ' + name) from exc
    if canonical != target:
        raise ValueError('non-canonical shaderc ZIP symlink target: ' + name)
    parent = name.rsplit('/', 1)[0]
    candidate = posixpath.normpath(posixpath.join(parent, canonical))
    if (not _shaderc_within_prefix(candidate, framework_prefix)
            or candidate == framework_prefix):
        raise ValueError('shaderc ZIP symlink target escapes framework: ' + name)
    return candidate


def _shaderc_resolve_archive_path(rows, requested, framework_prefix,
                                  *, max_hops=SHADERC_MAX_LINK_HOPS):
    """Resolve a requested archive path through indexed links only.

    The resolver follows a known link component such as Versions/Current in
    the in-archive index.  It never calls Path.resolve/readlink and returns the
    final indexed file or directory row.
    """
    if type(rows) is not dict or type(max_hops) is not int or max_hops < 0:
        raise ValueError('invalid shaderc ZIP resolver inputs')
    try:
        framework_prefix = _shaderc_archive_name(framework_prefix)
        current = _shaderc_archive_name(requested)
    except ValueError as exc:
        raise ValueError('unsafe shaderc ZIP resolver path') from exc
    if not _shaderc_within_prefix(current, framework_prefix):
        raise ValueError('shaderc ZIP resolver path escapes framework')

    framework_parts = framework_prefix.split('/')
    seen = set()
    hops = 0
    while True:
        if current in seen:
            raise ValueError('shaderc ZIP symlink cycle')
        seen.add(current)
        row = rows.get(current)
        if row is not None:
            kind = row.get('kind') if isinstance(row, dict) else None
            if kind == 'symlink':
                if row.get('directory') is not False:
                    raise ValueError('shaderc ZIP symlink directory shape')
                hops += 1
                if hops > max_hops:
                    raise ValueError('shaderc ZIP symlink hop bound')
                current = _shaderc_link_target(current, row.get('target'),
                                               framework_prefix)
                continue
            if kind in ('file', 'directory'):
                return current, row
            raise ValueError('invalid shaderc ZIP resolver row: ' + current)

        # A requested target can be below a known link component.  Prefer the
        # longest such component, then retain the suffix inside this framework.
        parts = current.split('/')
        link_prefix = None
        for index in range(len(parts) - 1, len(framework_parts), -1):
            candidate = '/'.join(parts[:index])
            candidate_row = rows.get(candidate)
            if candidate_row is None:
                continue
            candidate_kind = (candidate_row.get('kind')
                              if isinstance(candidate_row, dict) else None)
            if candidate_kind == 'symlink':
                link_prefix = candidate
                break
            if candidate_kind != 'directory':
                raise ValueError('shaderc ZIP regular-file ancestor: ' + candidate)
        if link_prefix is None:
            raise ValueError('missing shaderc ZIP symlink target: ' + current)
        link_row = rows[link_prefix]
        hops += 1
        if hops > max_hops:
            raise ValueError('shaderc ZIP symlink hop bound')
        replacement = _shaderc_link_target(link_prefix,
                                            link_row.get('target'),
                                            framework_prefix)
        suffix = current[len(link_prefix):].lstrip('/')
        current = replacement + (('/' + suffix) if suffix else '')


def _shaderc_validate_xc_links(rows):
    """Require the authenticated three-link macOS framework closure."""
    links = {name: row for name, row in rows.items()
             if row.get('kind') == 'symlink'}
    if set(links) != set(SHADERC_XC_LINKS):
        raise ValueError('shaderc XCFramework symlink set differs')
    expected_final = {
        SHADERC_XC_MAC_FRAMEWORK + '/Resources':
            (SHADERC_XC_MAC_FRAMEWORK + '/Versions/A/Resources', 'directory'),
        SHADERC_XC_MAC_FRAMEWORK + '/Libshaderc_combined':
            (SHADERC_XC_MAC_FRAMEWORK + '/Versions/A/Libshaderc_combined', 'file'),
        SHADERC_XC_MAC_FRAMEWORK + '/Versions/Current':
            (SHADERC_XC_MAC_FRAMEWORK + '/Versions/A', 'directory'),
    }
    for name, target in SHADERC_XC_LINKS.items():
        row = links[name]
        if row.get('target') != target:
            raise ValueError('shaderc XCFramework symlink target differs: ' + name)
        resolved_name, resolved_row = _shaderc_resolve_archive_path(
            rows, name, SHADERC_XC_MAC_FRAMEWORK)
        expected_name, expected_kind = expected_final[name]
        if (resolved_name != expected_name
                or resolved_row.get('kind') != expected_kind):
            raise ValueError('shaderc XCFramework symlink target missing: ' + name)


def _shaderc_zip_index(path, *, role='all'):
    """Index a bounded ZIP; links are permitted only for the fixed XC role."""
    if role not in ('all', 'xcframework'):
        raise ValueError('invalid shaderc ZIP role')
    rows, folded, total = {}, set(), 0
    with zipfile.ZipFile(path) as archive:
        infos = archive.infolist()
        if len(infos) > SHADERC_MAX_ENTRIES:
            raise ValueError('shaderc ZIP entry bound')
        for info in infos:
            name = _shaderc_archive_name(info.filename)
            key = name.casefold()
            if key in folded:
                raise ValueError('duplicate/case-colliding shaderc ZIP entry')
            folded.add(key)
            mode = (info.external_attr >> 16) & 0xffff
            file_type = stat.S_IFMT(mode)
            directory = info.is_dir()
            symlink = file_type == stat.S_IFLNK
            if symlink:
                if role != 'xcframework' or name not in SHADERC_XC_LINKS:
                    raise ValueError('unlisted shaderc ZIP symlink')
                if directory:
                    raise ValueError('shaderc ZIP symlink directory shape')
            elif file_type not in (0, stat.S_IFREG, stat.S_IFDIR):
                raise ValueError('special/symlink shaderc ZIP entry')
            if file_type == stat.S_IFDIR and not directory:
                raise ValueError('shaderc ZIP directory shape')
            if directory and file_type not in (0, stat.S_IFDIR):
                raise ValueError('shaderc ZIP directory shape')
            if info.flag_bits & 1:
                raise ValueError('encrypted shaderc ZIP entry')
            total += info.file_size
            if info.file_size > SHADERC_MAX_MEMBER or total > SHADERC_MAX_TOTAL:
                raise ValueError('shaderc ZIP inflated byte bound')
            row = {'info': info, 'directory': directory,
                   'bytes': info.file_size, 'compressedBytes': info.compress_size,
                   'kind': 'symlink' if symlink else ('directory' if directory else 'file')}
            if symlink:
                target, raw_bytes, raw_sha256 = _shaderc_link_body(archive, info, name)
                if target != SHADERC_XC_LINKS[name]:
                    raise ValueError('shaderc XCFramework symlink target differs: ' + name)
                row.update(target=target, rawBytes=raw_bytes,
                           rawSHA256=raw_sha256)
            rows[name] = row

        # Reject case-ambiguous implicit prefixes as well as exact duplicates.
        prefixes = {}
        for name in rows:
            pieces = name.split('/')
            for index in range(1, len(pieces) + 1):
                prefix = '/'.join(pieces[:index])
                folded_prefix = prefix.casefold()
                prior = prefixes.get(folded_prefix)
                if prior is not None and prior != prefix:
                    raise ValueError('case-colliding shaderc ZIP path')
                prefixes[folded_prefix] = prefix

        # A regular file or link may not be an ancestor of any archive entry.
        for name, row in rows.items():
            parts = name.split('/')
            for index in range(1, len(parts)):
                ancestor = '/'.join(parts[:index])
                ancestor_row = rows.get(ancestor)
                if ancestor_row is not None and not ancestor_row['directory']:
                    raise ValueError('shaderc ZIP file/symlink ancestor')
    if role == 'xcframework':
        _shaderc_validate_xc_links(rows)
    return rows


def _shaderc_entry_sha(path, rows, name):
    row = rows.get(name)
    if row is None or row.get('kind') != 'file':
        raise ValueError('missing shaderc ZIP regular entry: ' + name)
    h = hashlib.sha256()
    count = 0
    with zipfile.ZipFile(path) as archive, archive.open(row['info']) as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            count += len(block)
            if count > SHADERC_MAX_MEMBER:
                raise ValueError('shaderc ZIP member exceeds bound: ' + name)
            h.update(block)
    if count != row['bytes']:
        raise ValueError('shaderc ZIP member length changed: ' + name)
    return count, h.hexdigest()


def _shaderc_receipt_rows(path):
    """Return authenticated hashes for the nine retained all-ZIP members."""
    rows = _shaderc_zip_index(path, role='all')
    result = {}
    for _, arch, platform_name in SHADERC_MATRIX:
        name = f'lib/{platform_name}/thin/{arch}/lib/libshaderc_combined.a'
        count, checksum = _shaderc_entry_sha(path, rows, name)
        result[name] = {'kind': 'file', 'bytes': count, 'sha256': checksum}
    return result


def _shaderc_tool_sha(path, label):
    """Hash a stable SDK tool; host hardlinks do not waive archive-input rules."""
    if not path.is_absolute() or path.is_symlink():
        raise ValueError('shaderc ' + label + ' must be an absolute regular SDK tool')

    def identity(info):
        return (info.st_dev, info.st_ino, info.st_mode, info.st_nlink,
                info.st_size, info.st_mtime_ns, info.st_ctime_ns)

    before = path.lstat()
    maximum = 128 * 1024**2
    if (not stat.S_ISREG(before.st_mode) or before.st_nlink < 1
            or not 0 < before.st_size <= maximum):
        raise ValueError('shaderc ' + label + ' is not a bounded regular SDK tool')
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    checksum = hashlib.sha256()
    count = 0
    with os.fdopen(descriptor, 'rb') as source:
        if identity(os.fstat(source.fileno())) != identity(before):
            raise ValueError('shaderc SDK tool changed before open: ' + label)
        for block in iter(lambda: source.read(1024 * 1024), b''):
            count += len(block)
            if count > maximum or count > before.st_size:
                raise ValueError('shaderc SDK tool exceeded its bound: ' + label)
            checksum.update(block)
        if identity(os.fstat(source.fileno())) != identity(before):
            raise ValueError('shaderc SDK tool changed while hashing: ' + label)
    if count != before.st_size or identity(path.lstat()) != identity(before):
        raise ValueError('shaderc SDK tool identity changed: ' + label)
    return checksum.hexdigest()


def _shaderc_lipo_identity():
    requested = Path('/usr/bin/xcrun')
    finder_sha256 = _shaderc_tool_sha(requested, 'xcrun finder')
    resolved_text = run('/usr/bin/xcrun', '--find', 'lipo').strip()
    if _shaderc_tool_sha(requested, 'xcrun finder') != finder_sha256:
        raise ValueError('shaderc xcrun finder changed during lookup')
    if (not resolved_text or '\x00' in resolved_text or not resolved_text.startswith('/')
            or len(resolved_text) > 4096):
        raise ValueError('xcrun returned an invalid lipo path')
    resolved = Path(resolved_text).resolve(strict=True)
    reader_sha256 = _shaderc_tool_sha(resolved, 'resolved lipo reader')
    toolchain = Path('/usr/bin/xcodebuild')
    toolchain_sha256 = _shaderc_tool_sha(toolchain, 'xcodebuild identity reader')
    toolchain_version = run('/usr/bin/xcodebuild', '-version').strip()
    if not toolchain_version or '\x00' in toolchain_version or len(toolchain_version) > 4096:
        raise ValueError('xcodebuild toolchain identity is invalid')
    if _shaderc_tool_sha(toolchain, 'xcodebuild identity reader') != toolchain_sha256:
        raise ValueError('shaderc xcodebuild identity reader changed during inspection')
    return ({'mode': 'xcrun-resolved-lipo', 'requestedReader': str(requested),
             'resolvedReader': str(resolved), 'readerSHA256': reader_sha256,
             'toolchainReader': str(toolchain), 'toolchainSHA256': toolchain_sha256,
             'toolchainVersion': toolchain_version}, resolved)


def _shaderc_thin_xc(source, arch, thin, lipo, architecture_count):
    """Only a true single-arch ar can be copied; a fat wrapper must be thinned."""
    with source.open('rb') as stream:
        prefix = stream.read(8)
    if prefix == b'!<arch>\n':
        if architecture_count != 1:
            raise ValueError('shaderc multi-architecture XCFramework binary is not fat')
        shutil.copyfile(source, thin)
    elif prefix[:4] in (b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca',
                        b'\xca\xfe\xba\xbf', b'\xbf\xba\xfe\xca'):
        run(str(lipo), str(source), '-thin', arch, '-output', str(thin))
    else:
        raise ValueError('shaderc XCFramework binary is not an ar or fat archive')


def _shaderc_matrix_from_archives(all_zip, xc_zip, work):
    all_rows = _shaderc_zip_index(all_zip, role='all')
    xc_rows = _shaderc_zip_index(xc_zip, role='xcframework')
    expected_all = {}
    expected_xc = {}
    for slice_name, arch, platform_name in SHADERC_MATRIX:
        all_name = f'lib/{platform_name}/thin/{arch}/lib/libshaderc_combined.a'
        xc_name = ('Libshaderc_combined.xcframework/' + slice_name +
                   '/Libshaderc_combined.framework/Libshaderc_combined')
        expected_all[(slice_name, arch)] = all_name
        expected_xc[(slice_name, arch)] = xc_name
    if set(expected_all.values()) - set(all_rows) or set(expected_xc.values()) - set(xc_rows):
        raise ValueError('shaderc ZIP lacks an exact nine-architecture input')
    reader, lipo = _shaderc_lipo_identity()
    slice_arches = {}
    for slice_name, arch, _ in SHADERC_MATRIX:
        slice_arches.setdefault(slice_name, set()).add(arch)
    rows = []
    with tempfile.TemporaryDirectory(prefix='.shaderc-lipo-', dir=work) as temporary:
        temporary = Path(temporary)
        sources = {}
        for source_index, slice_name in enumerate(slice_arches):
            xc_name = next(expected_xc[(candidate, candidate_arch)]
                           for candidate, candidate_arch, _ in SHADERC_MATRIX
                           if candidate == slice_name)
            framework_prefix = xc_name.rsplit('/Libshaderc_combined', 1)[0]
            resolved_xc_name, resolved_xc_row = _shaderc_resolve_archive_path(
                xc_rows, xc_name, framework_prefix)
            expected_xc_name = xc_name
            if slice_name == 'macos-arm64_x86_64':
                expected_xc_name = framework_prefix + '/Versions/A/Libshaderc_combined'
            if (resolved_xc_name != expected_xc_name
                    or resolved_xc_row.get('kind') != 'file'):
                raise ValueError('shaderc XCFramework binary did not resolve to a regular member: '
                                 + xc_name)
            source = temporary / ('source-' + str(source_index))
            with zipfile.ZipFile(xc_zip) as archive, archive.open(
                    resolved_xc_row['info']) as stream:
                with source.open('xb') as sink:
                    copied = 0
                    for block in iter(lambda: stream.read(1024 * 1024), b''):
                        copied += len(block)
                        if copied > SHADERC_MAX_MEMBER:
                            raise ValueError('shaderc XCFramework binary exceeds bound')
                        sink.write(block)
            if copied != resolved_xc_row['bytes']:
                raise ValueError('shaderc XCFramework binary length changed')
            _shaderc_regular(source, 'temporary XCFramework binary')
            listed_arches = run(str(lipo), '-archs', str(source)).split()
            expected_arches = slice_arches[slice_name]
            if len(listed_arches) != len(set(listed_arches)) or set(listed_arches) != expected_arches:
                raise ValueError('shaderc XCFramework architecture set differs: ' + slice_name)
            sources[slice_name] = source
        for index, (slice_name, arch, platform_name) in enumerate(SHADERC_MATRIX):
            all_name = expected_all[(slice_name, arch)]
            all_bytes, all_sha256 = _shaderc_entry_sha(all_zip, all_rows, all_name)
            restored = (work / 'dist' / 'libshaderc' / platform_name / 'thin' / arch / 'lib'
                        / 'libshaderc_combined.a')
            if restored.parent.resolve() != restored.parent:
                raise ValueError('shaderc restored archive path contains a link')
            restored_bytes, restored_sha256 = _shaderc_file_sha(
                restored, 'restored ' + all_name)
            if (restored_bytes, restored_sha256) != (all_bytes, all_sha256):
                raise ValueError('shaderc restored thin archive differs: ' + all_name)
            source = sources[slice_name]
            thin = temporary / ('thin-' + str(index))
            _shaderc_thin_xc(source, arch, thin, lipo, len(slice_arches[slice_name]))
            xc_bytes, xc_sha256 = _shaderc_file_sha(thin, 'lipo output')
            if all_sha256 != xc_sha256:
                raise ValueError('shaderc all/XCFramework archive mismatch: ' + all_name)
            rows.append({'slice': slice_name, 'arch': arch, 'allZipEntry': all_name,
                         'allArchiveSHA256': all_sha256, 'xcArchiveSHA256': xc_sha256,
                         'equal': all_sha256 == xc_sha256})
    if _shaderc_tool_sha(lipo, 'resolved lipo reader') != reader['readerSHA256']:
        raise ValueError('shaderc lipo reader changed during matrix inspection')
    if (_shaderc_tool_sha(Path(reader['toolchainReader']), 'xcodebuild identity reader')
            != reader['toolchainSHA256']):
        raise ValueError('shaderc xcodebuild reader changed during matrix inspection')
    return reader, rows


def apple_shaderc_inputs(work):
    """Inspect fixed Shaderc inputs once and emit the producer coherence receipt."""
    work = work.absolute()
    if work.is_symlink() or not work.is_dir() or work.resolve() != work:
        raise ValueError('shaderc WORK must be a real absolute directory')
    input_dir = work / 'dist' / ('libshaderc-' + SHADERC_WRAPPER_VERSION)
    if input_dir.is_symlink() or not input_dir.is_dir() or input_dir.resolve() != input_dir:
        raise ValueError('shaderc input directory is not a real wrapper directory')
    all_zip, xc_zip = (input_dir / name for name, _, _ in SHADERC_SOURCE_SPECS)
    sources = [_shaderc_body(path, name, size, checksum)
               for path, (name, size, checksum) in zip((all_zip, xc_zip), SHADERC_SOURCE_SPECS, strict=True)]
    reader, matrix = _shaderc_matrix_from_archives(all_zip, xc_zip, work)
    receipt = {'schema': 1, 'profile': NATIVE_UPGRADES_PROFILE,
               'wrapperVersion': SHADERC_WRAPPER_VERSION,
               'validatorSHA256': digest(Path(__file__)), 'reader': reader,
               'sources': sources, 'matrix': matrix,
               'runtimeSecurityTested': False, 'promotionEligible': False}
    destination = input_dir / 'vortx-shaderc-inputs.json'
    if destination.exists() or destination.is_symlink():
        raise ValueError('refusing an existing Shaderc input receipt')
    save(destination, receipt)
    print('PASS apple-shaderc-inputs')


def apple_shaderc_receipt(input_dir):
    """Revalidate receipt/body identity only; never run lipo or native inspection."""
    input_dir = input_dir.absolute()
    if input_dir.is_symlink() or not input_dir.is_dir() or input_dir.resolve() != input_dir:
        raise ValueError('shaderc receipt directory is not a real absolute directory')
    receipt_path = input_dir / 'vortx-shaderc-inputs.json'
    if receipt_path.is_symlink() or not receipt_path.is_file():
        raise ValueError('missing Shaderc input receipt')
    _shaderc_regular(receipt_path, 'receipt')
    if receipt_path.stat().st_size > 1024 * 1024:
        raise ValueError('Shaderc receipt exceeds bound')
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError('duplicate Shaderc receipt key')
            result[key] = value
        return result
    with receipt_path.open('rb') as stream:
        encoded = stream.read(1024 * 1024 + 1)
    if len(encoded) > 1024 * 1024:
        raise ValueError('Shaderc receipt exceeds bound')
    value = json.loads(encoded, object_pairs_hook=unique,
                       parse_constant=lambda _: (_ for _ in ()).throw(ValueError('nonfinite receipt JSON')))
    for name, size, checksum in SHADERC_SOURCE_SPECS:
        _shaderc_body(input_dir / name, name, size, checksum)
    _shaderc_receipt_shape(value, {name: {'bytes': size, 'sha256': checksum}
                                   for name, size, checksum in SHADERC_SOURCE_SPECS},
                           digest(Path(__file__)),
                           _shaderc_receipt_rows(input_dir / SHADERC_SOURCE_SPECS[0][0]))
    print('PASS apple-shaderc-receipt')


def _shaderc_receipt_shape(value, source_specs, validator_sha256, retained_all_rows=None):
    """Strict receipt shape shared by the producer re-read and offline policy."""
    if retained_all_rows is not None and type(retained_all_rows) is not dict:
        raise ValueError('invalid retained Shaderc all-ZIP index')
    if type(value) is not dict or set(value) != {'schema', 'profile', 'wrapperVersion',
        'validatorSHA256', 'reader', 'sources', 'matrix', 'runtimeSecurityTested',
        'promotionEligible'}:
        raise ValueError('unexpected Shaderc receipt keys')
    if (type(value['schema']) is not int or value['schema'] != 1
            or value['profile'] != NATIVE_UPGRADES_PROFILE
            or value['wrapperVersion'] != SHADERC_WRAPPER_VERSION
            or value['validatorSHA256'] != validator_sha256
            or value['runtimeSecurityTested'] is not False
            or value['promotionEligible'] is not False):
        raise ValueError('invalid Shaderc receipt identity/boundary')
    reader = value['reader']
    if (type(reader) is not dict or set(reader) != {'mode', 'requestedReader', 'resolvedReader',
        'readerSHA256', 'toolchainReader', 'toolchainSHA256', 'toolchainVersion'}
            or reader['mode'] != 'xcrun-resolved-lipo'
            or reader['requestedReader'] != '/usr/bin/xcrun'
            or reader['toolchainReader'] != '/usr/bin/xcodebuild'
            or not isinstance(reader['toolchainSHA256'], str)
            or not re.fullmatch(r'[0-9a-f]{64}', reader['toolchainSHA256'])
            or not isinstance(reader['resolvedReader'], str)
            or not reader['resolvedReader'].startswith('/')
            or '\x00' in reader['resolvedReader']
            or len(reader['resolvedReader']) > 4096
            or not isinstance(reader['readerSHA256'], str)
            or not isinstance(reader['toolchainVersion'], str)
            or not reader['toolchainVersion'].strip()
            or '\x00' in reader['toolchainVersion']
            or len(reader['toolchainVersion']) > 4096
            or not re.fullmatch(r'[0-9a-f]{64}', reader['readerSHA256'])):
        raise ValueError('invalid Shaderc reader identity')
    sources = value['sources']
    if type(sources) is not list or len(sources) != len(SHADERC_SOURCE_SPECS):
        raise ValueError('invalid Shaderc source rows')
    seen = set()
    for row in sources:
        if type(row) is not dict or set(row) != {'name', 'bytes', 'sha256'}:
            raise ValueError('invalid Shaderc source row')
        name = row['name']
        if (not isinstance(name, str) or name in seen or name not in source_specs
                or type(row['bytes']) is not int or not isinstance(row['sha256'], str)):
            raise ValueError('unexpected Shaderc source name/bytes')
        if row != dict(name=name, bytes=source_specs[name]['bytes'], sha256=source_specs[name]['sha256']):
            raise ValueError('Shaderc source identity differs from pinned body')
        seen.add(name)
    if seen != set(source_specs):
        raise ValueError('incomplete Shaderc source set')
    expected = {(slice_name, arch, platform_name):
                ('lib/' + platform_name + '/thin/' + arch + '/lib/libshaderc_combined.a',
                 'Libshaderc_combined.xcframework/' + slice_name +
                 '/Libshaderc_combined.framework/Libshaderc_combined')
                for slice_name, arch, platform_name in SHADERC_MATRIX}
    matrix = value['matrix']
    if type(matrix) is not list or len(matrix) != len(expected):
        raise ValueError('invalid Shaderc matrix rows')
    observed = set()
    for row in matrix:
        if type(row) is not dict or set(row) != {'slice', 'arch', 'allZipEntry',
            'allArchiveSHA256', 'xcArchiveSHA256', 'equal'}:
            raise ValueError('invalid Shaderc matrix row')
        if (not isinstance(row['slice'], str) or not isinstance(row['arch'], str)
                or not isinstance(row['allZipEntry'], str)
                or not isinstance(row['allArchiveSHA256'], str)
                or not isinstance(row['xcArchiveSHA256'], str)):
            raise ValueError('invalid Shaderc matrix row types')
        identity = (row['slice'], row['arch'])
        key = next((candidate for candidate in expected if candidate[:2] == identity), None)
        if key is None or key in observed or row['allZipEntry'] != expected[key][0]:
            raise ValueError('unexpected Shaderc matrix path/identity')
        if (not re.fullmatch(r'[0-9a-f]{64}', row['allArchiveSHA256'])
                or not re.fullmatch(r'[0-9a-f]{64}', row['xcArchiveSHA256'])
                or row['equal'] is not True
                or row['allArchiveSHA256'] != row['xcArchiveSHA256']):
            raise ValueError('Shaderc matrix digest mismatch')
        if retained_all_rows is not None:
            retained = retained_all_rows.get(row['allZipEntry'])
            if (not isinstance(retained, dict) or retained.get('kind') != 'file'
                    or retained.get('sha256') != row['allArchiveSHA256']):
                raise ValueError('Shaderc matrix digest differs from retained all-ZIP member')
        if expected[key][1] != ('Libshaderc_combined.xcframework/' + identity[0] +
                                '/Libshaderc_combined.framework/Libshaderc_combined'):
            raise ValueError('Shaderc matrix XCFramework path mapping')
        observed.add(key)
    if observed != set(expected):
        raise ValueError('incomplete Shaderc matrix')
    return value


def _openssl_load(path, label):
    _shaderc_regular(path, label)
    if path.stat().st_size > OPENSSL_MAX_RECEIPT:
        raise ValueError('OpenSSL ' + label + ' exceeds its JSON bound')

    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError('duplicate OpenSSL ' + label + ' key')
            result[key] = value
        return result

    with path.open('rb') as stream:
        encoded = stream.read(OPENSSL_MAX_RECEIPT + 1)
    if len(encoded) > OPENSSL_MAX_RECEIPT:
        raise ValueError('OpenSSL ' + label + ' exceeds its JSON bound')
    return json.loads(encoded, object_pairs_hook=unique,
                      parse_constant=lambda _: (_ for _ in ()).throw(
                          ValueError('nonfinite OpenSSL JSON')))


def _openssl_expected(platform, arch, work):
    for candidate_platform, candidate_arch, target, slice_name in OPENSSL_MATRIX:
        if (candidate_platform, candidate_arch) == (platform, arch):
            prefix = work / 'dist' / 'openssl' / platform / 'thin' / arch
            return target, slice_name, prefix
    raise ValueError('unknown OpenSSL platform/architecture')


def _openssl_effective_configuration(value, environment, target):
    """Validate the bounded configdata.pm whitelist emitted after install_sw."""
    if type(value) is not dict or set(value) != set(OPENSSL_EFFECTIVE_KEYS):
        raise ValueError('OpenSSL effective configuration keys differ from the fixed whitelist')
    for key in OPENSSL_EFFECTIVE_KEYS:
        item = value[key]
        if key == 'CROSS_COMPILE':
            if item is not None:
                raise ValueError('OpenSSL CROSS_COMPILE must be JSON null for this profile')
            continue
        if isinstance(item, str):
            if not item or len(item) > 65536 or '\x00' in item:
                raise ValueError('OpenSSL effective configuration string is unbounded')
        elif isinstance(item, list):
            if len(item) > 4096 or any(not isinstance(part, str) or not part
                                       or len(part) > 65536 or '\x00' in part
                                       for part in item):
                raise ValueError('OpenSSL effective configuration list is unbounded')
        else:
            raise ValueError('OpenSSL effective configuration value is not JSON text/list')
    if (value['target'] != target or value['CC'] != environment['CC']
            or value['CXX'] != environment['CXX'] or value['AR'] != environment['AR']
            or value['RANLIB'] != environment['RANLIB']
            or value['ARFLAGS'] != ['qc']):
        raise ValueError('OpenSSL effective compiler/tool configuration differs from the environment')
    if (value['CFLAGS'] != [environment['CFLAGS']]
            or value['CPPFLAGS'] != [environment['CPPFLAGS']]
            or value['CXXFLAGS'] != [environment['CXXFLAGS']]
            or value['LDFLAGS'] != [environment['LDFLAGS']]):
        raise ValueError('OpenSSL effective make flags differ from the fixed environment')
    if value['lib_cppflags'] != '-DL_ENDIAN':
        raise ValueError('OpenSSL effective library CPP flags differ from the target config')
    cflags = value['cflags'] if isinstance(value['cflags'], list) else [value['cflags']]
    if '-fno-common' not in cflags:
        raise ValueError('OpenSSL effective C flags omit the fixed target flag')
    return value


def _openssl_environment(value, platform, arch, sdk_root, source_directory, build_directory):
    if type(value) is not dict or set(value) != set(OPENSSL_ENV_KEYS):
        raise ValueError('OpenSSL environment keys differ from the fixed build map')
    if any(not isinstance(value[key], str) or len(value[key]) > 65536
           or '\x00' in value[key] for key in OPENSSL_ENV_KEYS):
        raise ValueError('OpenSSL environment value is not bounded text')
    if (value['CC'] != '/usr/bin/clang' or value['CXX'] != '/usr/bin/clang++'
            or value['CURRENT_ARCH'] != arch or value['LC_CTYPE'] != 'C'
            or value['PKG_CONFIG_PATH'] != '' or value['PATH'] != OPENSSL_DEFAULT_PATH
            or value['ARFLAGS'] != 'qc' or value['MAKEFLAGS'] != '-j1'
            or value['CMAKE_BUILD_PARALLEL_LEVEL'] != '1'
            or value['CARGO_BUILD_JOBS'] != '1'):
        raise ValueError('OpenSSL environment has an unexpected fixed value')
    for key, suffix in (('AR', 'ar'), ('RANLIB', 'ranlib')):
        path = value[key]
        if (not path.startswith('/') or '..' in Path(path).parts
                or len(path) > 4096 or Path(path).name != suffix
                or not re.fullmatch(r'/.+/Toolchains/[^/]+\.xctoolchain/usr/bin/' + suffix, path)):
            raise ValueError('OpenSSL ' + key + ' is not the selected absolute SDK tool')
    sdk = Path(sdk_root)
    if (not sdk_root.startswith('/') or '\x00' in sdk_root or '..' in sdk.parts):
        raise ValueError('OpenSSL SDK root is not a safe absolute path')
    sdk_suffix = {
        'ios': ('iPhoneOS', 'iPhoneOS.sdk'),
        'isimulator': ('iPhoneSimulator', 'iPhoneSimulator.sdk'),
        'tvos': ('AppleTVOS', 'AppleTVOS.sdk'),
        'tvsimulator': ('AppleTVSimulator', 'AppleTVSimulator.sdk'),
        'macos': ('MacOSX', 'MacOSX.sdk'),
    }[platform]
    sdk_pattern = (r'.*/' + re.escape(sdk_suffix[0]) +
                   r'\.platform/Developer/SDKs/' + re.escape(sdk_suffix[0]) +
                   r'(?:[0-9]{1,3}(?:\.[0-9]{1,3}){0,3})?\.sdk')
    if not re.fullmatch(sdk_pattern, str(sdk)):
        raise ValueError('OpenSSL SDK root does not match the fixed platform')
    cpu = 'arm64' if arch in ('arm64', 'arm64e') else 'x86_64'
    minimum = {'ios': '15.0', 'isimulator': '15.0', 'tvos': '15.0',
               'tvsimulator': '15.0', 'macos': '12.0'}[platform]
    target = {
        'ios': cpu + '-apple-ios' + minimum,
        'isimulator': cpu + '-apple-ios' + minimum + '-simulator',
        'tvos': cpu + '-apple-tvos' + minimum,
        'tvsimulator': cpu + '-apple-tvos' + minimum + '-simulator',
        'macos': cpu + '-apple-macos' + minimum,
    }[platform]
    minimum_flag = {
        'ios': '-mios-version-min=' + minimum,
        'isimulator': '-mios-simulator-version-min=' + minimum,
        'tvos': '-mtvos-version-min=' + minimum,
        'tvsimulator': '-mtvos-simulator-version-min=' + minimum,
        'macos': '-mmacosx-version-min=' + minimum,
    }[platform]
    common = '-arch ' + arch + ' -isysroot ' + sdk_root + ' -target ' + target + ' ' + minimum_flag
    cflags = common + (' -DHAVE_FORK=0' if platform in ('tvos', 'tvsimulator') else '')
    if not (value['CFLAGS'] == value['CXXFLAGS'] == cflags + ' -O3'
            and value['CPPFLAGS'] == value['ASMFLAGS'] == cflags
            and value['LDFLAGS'] == '-lc++ ' + common):
        raise ValueError('OpenSSL compiler/linker flags differ from the fixed platform policy')
    source = Path(source_directory)
    build = Path(build_directory)
    if (not source_directory.startswith('/') or not build_directory.startswith('/')
            or '\x00' in source_directory or '\x00' in build_directory
            or source.name != OPENSSL_ROOT or source.parent.name != 'dist'
            or build != source.parent / OPENSSL_OUTPUT_ROOT / platform / 'scratch' / arch):
        raise ValueError('OpenSSL source/build directory identity differs from the fixed layout')
    expected_pkg = [str(source.parent / library / platform / 'thin' / arch / 'lib' / 'pkgconfig')
                    for library in OPENSSL_PKG_LIBRARIES]
    expected_pkg.append(str(build / 'vortx-sdk-pkgconfig'))
    if value['PKG_CONFIG_LIBDIR'] != ':'.join(expected_pkg):
        raise ValueError('OpenSSL pkg-config target roots differ from the fixed ordered map')
    return value


def _openssl_target_config(value, platform, arch, target):
    if (not isinstance(value, str) or not value or len(value.encode('utf-8')) > OPENSSL_MAX_TARGET_CONFIG
            or '\x00' in value or not value.endswith('\n')):
        raise ValueError('OpenSSL generated target config is not bounded text')
    expected = ('my %targets = (\n'
                '    "' + target + '" => {\n'
                '        inherit_from => [ "darwin-common" ],\n'
                '        CC => "/usr/bin/clang",\n'
                '        cflags => "-fno-common",\n'
                '        lib_cppflags => "-DL_ENDIAN",\n'
                '        bn_ops => "SIXTY_FOUR_BIT_LONG",\n'
                '        asm_arch => "' + ('aarch64' if arch in ('arm64', 'arm64e') else 'x86_64') + '",\n'
                '        perlasm_scheme => "' + ('ios64' if arch in ('arm64', 'arm64e') else 'macosx') + '",\n'
                '        sys_id => "' + ('MACOSX' if platform == 'macos' else 'iOS') + '",\n'
                '    },\n'
                ');\n\n')
    if value != expected:
        raise ValueError('OpenSSL generated target config differs from the fixed template')
    return value


def _openssl_validate_scratch(value, work, platform, arch, scratch):
    target, slice_name, prefix = _openssl_expected(platform, arch, work)
    expected_keys = {'schema', 'version', 'sourceSHA', 'sourceTag', 'platform', 'arch',
                     'configureTarget', 'configureArguments', 'sdkRoot', 'sourceDirectory',
                     'buildDirectory', 'prefix', 'environment', 'targetConfig',
                     'targetConfigSHA256', 'effectiveConfiguration', 'compiled', 'installed'}
    if type(value) is not dict or set(value) != expected_keys:
        raise ValueError('unexpected OpenSSL scratch record keys')
    if (type(value['schema']) is not int or value['schema'] != 1
            or value['version'] != OPENSSL_SOURCE['version']
            or value['sourceSHA'] != OPENSSL_SOURCE['commit']
            or value['sourceTag'] != OPENSSL_SOURCE['tag']
            or value['platform'] != platform or value['arch'] != arch
            or value['configureTarget'] != target or value['compiled'] is not True
            or value['installed'] is not True):
        raise ValueError('OpenSSL scratch source/platform/target/completion differs from the fixed profile')
    for field in ('sdkRoot', 'sourceDirectory', 'buildDirectory', 'prefix'):
        if (not isinstance(value[field], str) or not value[field].startswith('/')
                or '\x00' in value[field] or len(value[field]) > 4096):
            raise ValueError('OpenSSL scratch ' + field + ' is not a bounded absolute path')
    if Path(value['buildDirectory']).resolve() != scratch.resolve():
        raise ValueError('OpenSSL scratch build directory differs from its exact scratch path')
    if Path(value['sourceDirectory']).resolve() != (work / 'dist' / OPENSSL_ROOT).resolve():
        raise ValueError('OpenSSL scratch source directory differs from the pinned source root')
    if Path(value['prefix']).resolve() != prefix.resolve():
        raise ValueError('OpenSSL scratch prefix differs from the expected thin root')
    expected_args = ['--config=' + str(scratch / 'vortx-openssl-target.conf'),
                     '--prefix=' + value['prefix'], *OPENSSL_CONFIGURE_FLAGS, target]
    if value['configureArguments'] != expected_args:
        raise ValueError('OpenSSL Configure arguments differ from the fixed profile')
    _openssl_environment(value['environment'], platform, arch, value['sdkRoot'],
                          value['sourceDirectory'], value['buildDirectory'])
    _openssl_target_config(value['targetConfig'], platform, arch, target)
    if value['targetConfigSHA256'] != hashlib.sha256(value['targetConfig'].encode('utf-8')).hexdigest():
        raise ValueError('OpenSSL generated target config digest differs')
    _openssl_effective_configuration(value['effectiveConfiguration'], value['environment'], target)
    return target, slice_name, prefix


def _openssl_hash_outputs(prefix):
    result = []
    for name, relative, limit in OPENSSL_OUTPUTS:
        path = prefix / relative
        count, checksum = _shaderc_file_sha(path, 'installed ' + name)
        if count > limit:
            raise ValueError('OpenSSL installed output exceeds its bound: ' + name)
        result.append({'name': name, 'path': relative, 'bytes': count, 'sha256': checksum})
    return result


def _openssl_receipt_shape(value, validator_sha256):
    expected_keys = {'schema', 'profile', 'sourceProfile', 'version', 'sourceSHA', 'sourceTag',
                     'validatorSHA256', 'matrix', 'runtimeSecurityTested', 'promotionEligible'}
    if type(value) is not dict or set(value) != expected_keys:
        raise ValueError('unexpected OpenSSL receipt keys')
    if (type(value['schema']) is not int or value['schema'] != 1
            or value['profile'] != NATIVE_UPGRADES_PROFILE
            or value['sourceProfile'] != OPENSSL_BOM_PROFILE
            or value['version'] != OPENSSL_SOURCE['version']
            or value['sourceSHA'] != OPENSSL_SOURCE['commit']
            or value['sourceTag'] != OPENSSL_SOURCE['tag']
            or value['validatorSHA256'] != validator_sha256
            or value['runtimeSecurityTested'] is not False
            or value['promotionEligible'] is not False):
        raise ValueError('invalid OpenSSL receipt identity/boundary')
    matrix = value['matrix']
    if type(matrix) is not list or len(matrix) != len(OPENSSL_MATRIX):
        raise ValueError('OpenSSL receipt must contain exactly nine matrix rows')
    expected = {(platform, arch): (target, slice_name)
                for platform, arch, target, slice_name in OPENSSL_MATRIX}
    observed = set()
    header_hashes = set()
    for row in matrix:
        row_keys = {'platform', 'arch', 'slice', 'configureTarget', 'configureArguments',
                    'sdkRoot', 'sourceDirectory', 'buildDirectory', 'prefix', 'environment',
                    'targetConfig', 'targetConfigSHA256', 'effectiveConfiguration',
                    'compiled', 'installed', 'outputs'}
        if type(row) is not dict or set(row) != row_keys:
            raise ValueError('unexpected OpenSSL receipt row keys')
        identity = (row['platform'], row['arch'])
        if (identity not in expected or identity in observed
                or row['slice'] != expected[identity][1]
                or row['configureTarget'] != expected[identity][0]
                or row['compiled'] is not True or row['installed'] is not True):
            raise ValueError('unexpected OpenSSL receipt platform/architecture/completion')
        for field in ('sdkRoot', 'sourceDirectory', 'buildDirectory', 'prefix'):
            if (not isinstance(row[field], str) or not row[field].startswith('/')
                    or '\x00' in row[field] or len(row[field]) > 4096):
                raise ValueError('OpenSSL receipt ' + field + ' is not a bounded absolute path')
        source_root = Path(row['sourceDirectory'])
        if (source_root.name != OPENSSL_ROOT or source_root.parent.name != 'dist'
                or Path(row['buildDirectory']) != source_root.parent / OPENSSL_OUTPUT_ROOT / row['platform'] /
                'scratch' / row['arch']
                or Path(row['prefix']) != source_root.parent / OPENSSL_OUTPUT_ROOT / row['platform'] /
                'thin' / row['arch']):
            raise ValueError('OpenSSL receipt source/build/prefix layout differs from the fixed tree')
        if not row['prefix'].endswith('/dist/' + OPENSSL_OUTPUT_ROOT + '/' + row['platform'] + '/thin/' + row['arch']):
            raise ValueError('OpenSSL receipt prefix differs from the fixed thin layout')
        expected_args = ['--config=' + row['buildDirectory'] + '/vortx-openssl-target.conf',
                         '--prefix=' + row['prefix'], *OPENSSL_CONFIGURE_FLAGS,
                         expected[identity][0]]
        if row['configureArguments'] != expected_args:
            raise ValueError('OpenSSL receipt Configure arguments differ from the fixed profile')
        _openssl_environment(row['environment'], row['platform'], row['arch'], row['sdkRoot'],
                             row['sourceDirectory'], row['buildDirectory'])
        _openssl_target_config(row['targetConfig'], row['platform'], row['arch'],
                               expected[identity][0])
        if row['targetConfigSHA256'] != hashlib.sha256(row['targetConfig'].encode('utf-8')).hexdigest():
            raise ValueError('OpenSSL receipt target config digest differs')
        _openssl_effective_configuration(row['effectiveConfiguration'], row['environment'],
                                          expected[identity][0])
        outputs = row['outputs']
        if type(outputs) is not list or len(outputs) != len(OPENSSL_OUTPUTS):
            raise ValueError('OpenSSL receipt output count differs from the fixed set')
        seen_outputs = set()
        for output in outputs:
            if type(output) is not dict or set(output) != {'name', 'path', 'bytes', 'sha256'}:
                raise ValueError('unexpected OpenSSL receipt output keys')
            name = output['name']
            fixed = next((candidate for candidate in OPENSSL_OUTPUTS if candidate[0] == name), None)
            if fixed is None or name in seen_outputs or output['path'] != fixed[1]:
                raise ValueError('unexpected OpenSSL receipt output path/name')
            if (type(output['bytes']) is not int or output['bytes'] < 1
                    or output['bytes'] > fixed[2]
                    or not re.fullmatch(r'[0-9a-f]{64}', output['sha256'])):
                raise ValueError('invalid OpenSSL receipt output bytes/hash')
            if name == 'opensslv.h':
                header_hashes.add(output['sha256'])
            seen_outputs.add(name)
        if seen_outputs != {name for name, _, _ in OPENSSL_OUTPUTS}:
            raise ValueError('incomplete OpenSSL receipt output set')
        observed.add(identity)
    if observed != set(expected) or len(header_hashes) != 1:
        raise ValueError('incomplete OpenSSL receipt matrix')
    return value


def _openssl_receipt_rows_from_scratch(value, outputs):
    return {'platform': value['platform'], 'arch': value['arch'],
            'slice': next(slice_name for platform, arch, _, slice_name in OPENSSL_MATRIX
                          if (platform, arch) == (value['platform'], value['arch'])),
            'configureTarget': value['configureTarget'],
            'configureArguments': value['configureArguments'], 'sdkRoot': value['sdkRoot'],
            'sourceDirectory': value['sourceDirectory'], 'buildDirectory': value['buildDirectory'],
            'prefix': value['prefix'], 'environment': value['environment'],
            'targetConfig': value['targetConfig'],
            'targetConfigSHA256': value['targetConfigSHA256'],
            'effectiveConfiguration': value['effectiveConfiguration'],
            'compiled': value['compiled'], 'installed': value['installed'], 'outputs': outputs}


def apple_openssl_builds(work):
    """Hash successful OpenSSL thin installs and emit the fixed source BOM."""
    work = work.absolute()
    if work.is_symlink() or not work.is_dir() or work.resolve() != work:
        raise ValueError('OpenSSL WORK must be a real absolute directory')
    matrix = []
    for platform, arch, _, _ in OPENSSL_MATRIX:
        scratch = work / 'dist' / 'openssl' / platform / 'scratch' / arch / 'vortx-openssl-build.json'
        record = _openssl_load(scratch, 'scratch record')
        _openssl_validate_scratch(record, work, platform, arch, scratch.parent)
        matrix.append(_openssl_receipt_rows_from_scratch(record,
                                                         _openssl_hash_outputs(
                                                             _openssl_expected(platform, arch, work)[2])))
    destination_root = work / 'dist' / OPENSSL_OUTPUT_ROOT
    if (destination_root.is_symlink() or not destination_root.is_dir()
            or destination_root.resolve() != destination_root):
        raise ValueError('OpenSSL destination root is not a real build directory')
    destination = destination_root / 'vortx-openssl-builds.json'
    if destination.exists() or destination.is_symlink():
        raise ValueError('refusing an existing OpenSSL BOM receipt')
    save(destination, {'schema': 1, 'profile': NATIVE_UPGRADES_PROFILE,
                       'sourceProfile': OPENSSL_BOM_PROFILE, 'version': OPENSSL_SOURCE['version'],
                       'sourceSHA': OPENSSL_SOURCE['commit'], 'sourceTag': OPENSSL_SOURCE['tag'],
                       'validatorSHA256': digest(Path(__file__)), 'matrix': matrix,
                       'runtimeSecurityTested': False, 'promotionEligible': False})
    print('PASS openssl-profile ' + OPENSSL_BOM_PROFILE)
    print('PASS apple-openssl-builds')


def apple_openssl_receipt(receipt_path):
    """Revalidate one OpenSSL BOM file and its installed outputs without native tools."""
    receipt_path = receipt_path.absolute()
    if (not receipt_path.is_absolute() or receipt_path.is_symlink()
            or receipt_path.resolve() != receipt_path
            or receipt_path.name != 'vortx-openssl-builds.json'
            or receipt_path.parent.name != OPENSSL_OUTPUT_ROOT
            or receipt_path.parent.parent.name != 'dist'):
        raise ValueError('OpenSSL receipt must be the exact generated BOM file')
    work = receipt_path.parent.parent.parent
    if work.is_symlink() or not work.is_dir() or work.resolve() != work:
        raise ValueError('OpenSSL receipt work root is not a real absolute directory')
    value = _openssl_load(receipt_path, 'receipt')
    _openssl_receipt_shape(value, digest(Path(__file__)))
    expected_rows = {(row['platform'], row['arch']): row for row in value['matrix']}
    for platform, arch, _, _ in OPENSSL_MATRIX:
        row = expected_rows[(platform, arch)]
        actual = _openssl_hash_outputs(work / 'dist' / 'openssl' / platform / 'thin' / arch)
        if actual != row['outputs']:
            raise ValueError('OpenSSL installed files differ from the BOM: ' + platform + '/' + arch)
    print('PASS openssl-profile ' + OPENSSL_BOM_PROFILE)
    print('PASS apple-openssl-receipt')


def _subtitle_json(body, label):
    def unique(pairs):
        value = {}
        for key, item in pairs:
            if key in value:
                raise ValueError('duplicate subtitle ' + label + ' key')
            value[key] = item
        return value

    try:
        return json.loads(body.decode('utf-8', errors='strict'), object_pairs_hook=unique,
                          parse_constant=lambda _: (_ for _ in ()).throw(
                              ValueError('non-finite subtitle ' + label + ' number')))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ValueError('invalid subtitle ' + label + ' JSON') from error


def _subtitle_inline(row, label, budget, maximum=SUBTITLE_MAX_BODY):
    if type(row) is not dict or set(row) != {'bytes', 'sha256', 'bodyBase64'}:
        raise ValueError('unexpected subtitle inline-body keys: ' + label)
    count = row['bytes']
    encoded = row['bodyBase64']
    if (type(count) is not int or not 0 < count <= maximum
            or not isinstance(encoded, str)
            or len(encoded) > ((maximum + 2) // 3) * 4
            or not re.fullmatch(r'[0-9a-f]{64}', row['sha256'])):
        raise ValueError('invalid subtitle inline-body bound: ' + label)
    try:
        body = base64.b64decode(encoded.encode('ascii'), validate=True)
    except (UnicodeEncodeError, binascii.Error) as error:
        raise ValueError('subtitle inline body is not canonical base64: ' + label) from error
    if (base64.b64encode(body).decode('ascii') != encoded or len(body) != count
            or hashlib.sha256(body).hexdigest() != row['sha256']):
        raise ValueError('subtitle inline raw-body identity differs: ' + label)
    budget[0] += len(body)
    if budget[0] > SUBTITLE_MAX_INLINE_RAW:
        raise ValueError('subtitle aggregate raw-body cap exceeded')
    return body


def _subtitle_text(body, label):
    try:
        text = body.decode('utf-8', errors='strict')
    except UnicodeDecodeError as error:
        raise ValueError('subtitle ' + label + ' is not UTF-8') from error
    if not text or '\x00' in text:
        raise ValueError('subtitle ' + label + ' is empty or contains NUL')
    return text


def _subtitle_platform(platform, arch):
    sdk_stem = {'ios': 'iPhoneOS', 'isimulator': 'iPhoneSimulator',
                'tvos': 'AppleTVOS', 'tvsimulator': 'AppleTVSimulator',
                'macos': 'MacOSX'}[platform]
    cpu = 'x86_64' if arch == 'x86_64' else 'arm64'
    target = {'ios': cpu + '-apple-ios15.0',
              'isimulator': cpu + '-apple-ios15.0-simulator',
              'tvos': cpu + '-apple-tvos15.0',
              'tvsimulator': cpu + '-apple-tvos15.0-simulator',
              'macos': cpu + '-apple-macos12.0'}[platform]
    minimum = {'ios': '-mios-version-min=15.0',
               'isimulator': '-mios-simulator-version-min=15.0',
               'tvos': '-mtvos-version-min=15.0',
               'tvsimulator': '-mtvos-simulator-version-min=15.0',
               'macos': '-mmacosx-version-min=12.0'}[platform]
    host_cpu = 'aarch64' if cpu == 'arm64' else cpu
    host = host_cpu + '-' + ({'ios': 'ios', 'isimulator': 'ios',
                         'tvos': 'tvos', 'tvsimulator': 'tvos',
                         'macos': 'apple'}[platform]) + '-darwin'
    subsystem = {'ios': 'ios', 'isimulator': 'ios-simulator',
                 'tvos': 'tvos', 'tvsimulator': 'tvos-simulator',
                 'macos': 'macos'}[platform]
    cpu_family = 'x86_64' if arch == 'x86_64' else 'aarch64'
    return sdk_stem, target, minimum, host, subsystem, cpu_family, cpu


def _subtitle_environment(value, work, library, platform, arch):
    keys = {'LC_CTYPE', 'MAKEFLAGS', 'CMAKE_BUILD_PARALLEL_LEVEL', 'CARGO_BUILD_JOBS',
            'CC', 'CXX', 'CURRENT_ARCH', 'CFLAGS', 'CPPFLAGS', 'CXXFLAGS',
            'ASMFLAGS', 'LDFLAGS', 'PKG_CONFIG_LIBDIR', 'PKG_CONFIG_PATH', 'PATH'}
    if type(value) is not dict or set(value) != keys:
        raise ValueError('subtitle environment keys differ from BaseBuild')
    if any(not isinstance(item, str) or len(item) > 65536 or '\x00' in item
           for item in value.values()):
        raise ValueError('subtitle environment contains unbounded text')
    sdk_stem, target, minimum, _, _, _, _ = _subtitle_platform(platform, arch)
    prefix = '-arch ' + arch + ' -isysroot '
    suffix = ' -target ' + target + ' ' + minimum
    fork = ' -DHAVE_FORK=0' if platform in ('tvos', 'tvsimulator') else ''
    freetype = work / 'dist/libfreetype' / platform / 'thin' / arch
    dependency_cflags = ' -I' + str(freetype / 'include') if library == 'libbluray' else ''
    cflags = value['CFLAGS']
    optimization = ' -O2' if library == 'libunibreak' else ''
    if optimization:
        if (not cflags.endswith(optimization)
                or [item for item in cflags.split() if item.startswith('-O')] != ['-O2']):
            raise ValueError('Unibreak shipping CFLAGS require exactly one trailing -O2')
        cflags = cflags[:-len(optimization)]
    if not cflags.startswith(prefix) or not cflags.endswith(suffix + fork + dependency_cflags):
        raise ValueError('subtitle C flags differ from the fixed platform policy')
    sdk_root = cflags[len(prefix):len(cflags) - len(suffix + fork + dependency_cflags)]
    sdk_pattern = (r'.*/' + re.escape(sdk_stem) +
                   r'\.platform/Developer/SDKs/' + re.escape(sdk_stem) +
                   r'(?:[0-9]{1,3}(?:\.[0-9]{1,3}){0,3})?\.sdk')
    if (not sdk_root.startswith('/') or '\x00' in sdk_root or '..' in Path(sdk_root).parts
            or re.fullmatch(sdk_pattern, sdk_root) is None):
        raise ValueError('subtitle SDK root differs from the fixed platform')
    build = work / 'dist' / library / platform / 'scratch' / arch
    pkg_roots = [str(work / 'dist' / name / platform / 'thin' / arch / 'lib/pkgconfig')
                 for name in OPENSSL_PKG_LIBRARIES]
    pkg_roots.append(str(build / 'vortx-sdk-pkgconfig'))
    if library == 'libfreetype':
        pkg_roots = [str(build / 'vortx-sdk-pkgconfig')]
    expected = {
        'LC_CTYPE': 'C', 'MAKEFLAGS': '-j1', 'CMAKE_BUILD_PARALLEL_LEVEL': '1',
        'CARGO_BUILD_JOBS': '1', 'CC': '/usr/bin/clang', 'CXX': '/usr/bin/clang++',
        'CURRENT_ARCH': arch, 'CFLAGS': cflags + optimization, 'CPPFLAGS': cflags,
        'CXXFLAGS': cflags + optimization, 'ASMFLAGS': cflags,
        'LDFLAGS': '-lc++ ' + prefix + sdk_root + suffix +
                   ((' -L' + str(freetype / 'lib') + ' -lfreetype') if library == 'libbluray' else ''),
        'PKG_CONFIG_LIBDIR': ':'.join(pkg_roots), 'PKG_CONFIG_PATH': '',
        'PATH': OPENSSL_DEFAULT_PATH,
    }
    if not _crypto_exact_equal(value, expected):
        raise ValueError('subtitle environment differs from exact BaseBuild output')
    return sdk_root, cflags, expected['LDFLAGS']


def _subtitle_meson_cross(body, work, library, platform, arch, sdk_root, cflags, ldflags):
    text = _subtitle_text(body, 'Meson cross file')
    tools = {}
    for name in ('ar', 'strip'):
        matches = re.findall(r"^" + name + r" = '([^']+)'$", text, re.M)
        if (len(matches) != 1 or not matches[0].startswith('/')
                or '..' in Path(matches[0]).parts or '\x00' in matches[0]
                or Path(matches[0]).name != name or len(matches[0]) > 4096):
            raise ValueError('subtitle Meson cross file has an unsafe SDK tool: ' + name)
        tools[name] = matches[0]
    _, _, _, _, subsystem, cpu_family, cpu = _subtitle_platform(platform, arch)
    quoted_c = ', '.join("'" + item + "'" for item in cflags.split(' '))
    quoted_ld = ', '.join("'" + item + "'" for item in ldflags.split(' '))
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
        ar=tools['ar'], strip=tools['strip'], subsystem=subsystem,
        cpu_family=cpu_family, cpu=cpu,
        prefix=work / 'dist' / library / platform / 'thin' / arch,
        cflags=quoted_c, ldflags=quoted_ld)
    if text.rstrip('\n') != expected:
        raise ValueError('subtitle Meson cross file differs from BaseBuild')


def _subtitle_build_options(body, library, prefix):
    value = _subtitle_json(body, 'Meson build options')
    if type(value) is not list or len(value) > 10000:
        raise ValueError('subtitle Meson build-option set is unbounded')
    options = {}
    for row in value:
        if type(row) is not dict or not isinstance(row.get('name'), str) or row['name'] in options:
            raise ValueError('subtitle Meson build-option row is malformed or duplicate')
        options[row['name']] = row.get('value')
    expected = {'default_library': 'static', 'buildtype': 'release',
                'prefix': str(prefix)}
    for argument in SUBTITLE_ARGUMENTS[library]:
        if argument == '--wrap-mode=nodownload':
            expected['wrap_mode'] = 'nodownload'
            continue
        if argument == '--force-fallback-for=libudfread':
            expected['force_fallback_for'] = ['libudfread']
            continue
        name, raw = argument.removeprefix('-D').split('=', 1)
        expected[name] = {'true': True, 'false': False}.get(raw, raw)
    if any(name not in options or not _crypto_exact_equal(options[name], item)
           for name, item in expected.items()):
        raise ValueError('subtitle Meson effective options differ from the fixed arguments')


def _subtitle_dependencies(body):
    value = _subtitle_json(body, 'Meson dependencies')
    if type(value) is not list or len(value) > 10000:
        raise ValueError('subtitle Meson dependency set is unbounded')
    text = json.dumps(value, sort_keys=True, separators=(',', ':')).casefold()
    forbidden = ('freetype', 'glib', 'gobject', 'cairo', 'chafa', 'libpng',
                 'zlib', 'icu', 'graphite2', 'fontations', 'harfrust', 'kbts',
                 'wrapdb')
    if any(re.search(r'(?<![a-z0-9_])' + re.escape(name) +
                     r'(?![a-z0-9_])', text) for name in forbidden):
        raise ValueError('subtitle Meson dependency closure admits a disabled integration')


def _subtitle_compile_command(row, arch, sdk_root, target, minimum, fribidi_role=None):
    if (type(row) is not dict or not 0 < len(row) <= 16
            or any(not isinstance(name, str) or not name or len(name) > 128
                   for name in row)):
        raise ValueError('subtitle compile-command row is malformed or unbounded')
    payloads = []
    if 'arguments' in row:
        arguments = row['arguments']
        if (type(arguments) is not list or not 0 < len(arguments) <= 16384
                or any(not isinstance(item, str) or not item or len(item) > 65536
                       or '\x00' in item for item in arguments)
                or sum(len(item) for item in arguments) > 1024 * 1024):
            raise ValueError('subtitle compile-command arguments are malformed or unbounded')
        payloads.append(arguments)
    if 'command' in row:
        command = row['command']
        if (not isinstance(command, str) or not command or len(command) > 1024 * 1024
                or '\x00' in command):
            raise ValueError('subtitle compile-command text is malformed or unbounded')
        try:
            arguments = shlex.split(command, posix=True)
        except ValueError as error:
            raise ValueError('subtitle compile-command text is not shell-tokenizable') from error
        if (not arguments or len(arguments) > 16384
                or any(not item or len(item) > 65536 for item in arguments)):
            raise ValueError('subtitle compile-command token set is malformed or unbounded')
        payloads.append(arguments)
    if not payloads:
        raise ValueError('subtitle compile-command row has no command payload')
    for arguments in payloads:
        alternate = [item for item in arguments
                     if ((item.startswith('-target') and item != '-target')
                         or item.startswith('--target')
                         or (item.startswith('-isysroot') and item != '-isysroot')
                         or item.startswith('--sysroot'))]
        if alternate:
            raise ValueError('subtitle compile-command has an alternate target/sysroot spelling')

        def values(flag):
            indexes = [index for index, item in enumerate(arguments) if item == flag]
            if any(index + 1 >= len(arguments) for index in indexes):
                raise ValueError('subtitle compile-command has an unterminated target flag')
            return [arguments[index + 1] for index in indexes]

        deployment = [item for item in arguments if re.fullmatch(
            r'-(?:mios|mios-simulator|mtvos|mtvos-simulator|mmacosx)-version-min=.*',
            item)]
        arch_values = values('-arch')
        sdk_values = values('-isysroot')
        target_values = values('-target')
        if fribidi_role is not None:
            source, output, native = fribidi_role
            if (arguments[0] != ('cc' if native else '/usr/bin/clang')
                    or any((item.startswith('-o') and item != '-o')
                           or item.startswith('--output') or item.startswith('@')
                           or item == '--' for item in arguments)
                    or values('-c') != [source] or values('-o') != [output]
                    or [item for item in arguments
                        if not item.startswith('-') and item.endswith('.c')] != [source]):
                raise ValueError('FriBidi compile-command compiler/source/output differs from its fixed role')
            if native:
                toggles = [item for item in arguments if re.match(
                    r'^-[DU](?:HAVE_CONFIG_H|HAVE_STRINGIZE|DONT_HAVE_FRIBIDI_CONFIG_H)(?:=|$)', item)]
                if (arch_values or sdk_values or target_values or deployment
                        or any(item.startswith('-arch') for item in arguments)
                        or any(item in ('-D', '-U') or
                               (item.startswith(('-D', '-U')) and any(char.isspace() for char in item))
                               for item in arguments)
                        or any(item.startswith(('-Wp,', '-Xpreprocessor', '-Xclang'))
                               for item in arguments)
                        or sorted(toggles) != sorted([
                            '-UHAVE_CONFIG_H', '-DHAVE_STRINGIZE', '-DDONT_HAVE_FRIBIDI_CONFIG_H'])):
                    raise ValueError('FriBidi native generator has shipping target flags or changed configuration defines')
                continue
        if (not arch_values or any(item != arch for item in arch_values)
                or not sdk_values or any(item != sdk_root for item in sdk_values)
                or not target_values or any(item != target for item in target_values)
                or not deployment or any(item != minimum for item in deployment)):
            raise ValueError('subtitle compile-command target flags differ from fixed policy')


def _subtitle_fribidi_compile_commands(commands, build, arch, sdk_root, target, minimum):
    # Exact pinned 1.0.17 gen.tab/meson.build: one native executable plus
    # six native table generators, each with its own source and packtab.c.
    root = '../../../../libfribidi-1.0.17-6949dcde/'
    expected = {}
    for program in ('gen-unicode-version', 'gen-bidi-type-tab',
                    'gen-joining-type-tab', 'gen-arabic-shaping-tab',
                    'gen-mirroring-tab', 'gen-brackets-tab', 'gen-brackets-type-tab'):
        names = (program + '.c',) if program == 'gen-unicode-version' else (program + '.c', 'packtab.c')
        for name in names:
            expected[(root + 'gen.tab/' + name, 'gen.tab/' + program + '.p/' + name + '.o')] = True
    # Pinned lib/meson.build's complete shipping source list (deprecated=true).
    for name in ('fribidi.c', 'fribidi-arabic.c', 'fribidi-bidi.c', 'fribidi-bidi-types.c',
                 'fribidi-char-sets.c', 'fribidi-char-sets-cap-rtl.c',
                 'fribidi-char-sets-cp1255.c', 'fribidi-char-sets-cp1256.c',
                 'fribidi-char-sets-iso8859-6.c', 'fribidi-char-sets-iso8859-8.c',
                 'fribidi-char-sets-utf8.c', 'fribidi-deprecated.c', 'fribidi-joining.c',
                 'fribidi-joining-types.c', 'fribidi-mirroring.c', 'fribidi-brackets.c',
                 'fribidi-run.c', 'fribidi-shape.c'):
        expected[(root + 'lib/' + name, 'lib/libfribidi.a.p/' + name + '.o')] = False
    if type(commands) is not list or len(commands) != len(expected):
        raise ValueError('FriBidi compile-command set must contain exactly 13 native and 18 shipping rows')
    seen = set()
    for row in commands:
        if (type(row) is not dict
                or not {'directory', 'file', 'output'} <= set(row)
                or set(row) - {'directory', 'file', 'output', 'command', 'arguments'}
                or not isinstance(row['file'], str) or not isinstance(row['output'], str)
                or row['directory'] != str(build)):
            raise ValueError('FriBidi compile-command metadata differs from the fixed build directory/schema')
        identity = (row['file'], row['output'])
        if identity not in expected or identity in seen:
            raise ValueError('FriBidi compile-command has an unknown or duplicate source/output role')
        seen.add(identity)
        _subtitle_compile_command(row, arch, sdk_root, target, minimum,
                                  (identity[0], identity[1], expected[identity]))
    if seen != set(expected):
        raise ValueError('FriBidi compile-command native/shipping closure is incomplete')


def _subtitle_pc(body, library, prefix):
    text = _subtitle_text(body, 'pkg-config metadata')
    variables, fields = {}, {}
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith('#'):
            continue
        if '=' in line and (':' not in line or line.index('=') < line.index(':')):
            name, item = line.split('=', 1)
            target = variables
        elif ':' in line:
            name, item = line.split(':', 1)
            target = fields
        else:
            raise ValueError('subtitle pkg-config metadata has an unclassified line')
        name, item = name.strip(), item.strip()
        if not name or name in target or '\x00' in item:
            raise ValueError('subtitle pkg-config metadata has a duplicate field')
        target[name] = item
    if variables.get('prefix') != str(prefix) or fields.get('Version') != ('26.7.20' if library == 'libfreetype' else SUBTITLE_VERSIONS[library]):
        raise ValueError('subtitle pkg-config prefix/version differs from the fixed build')
    if library == 'libfreetype':
        if fields.get('Requires') != 'zlib' or fields.get('Requires.private', '') or fields.get('Libs') != '-L${libdir} -lfreetype' or fields.get('Cflags') != '-I${includedir}/freetype2':
            raise ValueError('FreeType exact system-zlib PC closure differs')
    elif library == 'libbluray':
        # Meson exposes static-library dependencies publicly; require that exact closure.
        if (re.fullmatch(r'freetype2,[ \t]+libxml-2\.0[ \t]+>=[ \t]+2\.6', fields.get('Requires', '')) is None
                or 'Requires.private' in fields
                or any(item in text for item in ('-ludfread', '/opt/homebrew', '/usr/local/', 'fontconfig'))):
            raise ValueError('libbluray pkg-config dependency closure differs')
    elif fields.get('Requires', '') or fields.get('Requires.private', ''):
        raise ValueError('subtitle pkg-config unexpectedly admits another package dependency')
    expected_lib = {'libunibreak': '-lunibreak', 'libfribidi': '-lfribidi',
                    'libharfbuzz': '-lharfbuzz', 'libbluray': '-lbluray', 'libfreetype': '-lfreetype'}[library]
    if expected_lib not in fields.get('Libs', '').split():
        raise ValueError('subtitle pkg-config library identity differs')


def _subtitle_header(body, library):
    text = _subtitle_text(body, 'installed version header')
    if library == 'libfreetype':
        for name, value in (('FREETYPE_MAJOR','2'),('FREETYPE_MINOR','15'),('FREETYPE_PATCH','0')):
            _bluray_define(text, name, value)
    elif library == 'libbluray':
        for name, value in (('BLURAY_VERSION_MAJOR', '1'), ('BLURAY_VERSION_MINOR', '5'), ('BLURAY_VERSION_MICRO', '0')):
            _bluray_define(text, name, value)
        _bluray_define(text, 'BLURAY_VERSION_STRING', '1.5.0', True)
    elif library == 'libunibreak':
        definitions = re.findall(r'^[ \t]*#[ \t]*define[ \t]+UNIBREAK_VERSION\b[^\r\n]*$',
                                 text, re.M)
        versions = re.findall(
            r'^[ \t]*#[ \t]*define[ \t]+UNIBREAK_VERSION[ \t]+'
            r'(0[xX][0-9a-fA-F]+)[ \t]*'
            r'(?:/\*(?:[^*\r\n]|\*(?!/)){0,4096}\*/[ \t]*)?$', text, re.M)
        symbols = re.findall(r'^\s*extern\s+const\s+int\s+unibreak_version\s*;\s*$',
                             text, re.M)
        if len(definitions) != 1 or versions != ['0x0800'] or len(symbols) != 1:
            raise ValueError('Unibreak installed header version differs')
    elif library == 'libfribidi':
        expected = {'FRIBIDI_MAJOR_VERSION': '1', 'FRIBIDI_MINOR_VERSION': '0',
                    'FRIBIDI_MICRO_VERSION': '17'}
        for name, version in expected.items():
            definitions = re.findall(r'^[ \t]*#[ \t]*define[ \t]+' +
                                     re.escape(name) + r'\b[^\r\n]*$', text, re.M)
            values = re.findall(r'^[ \t]*#[ \t]*define[ \t]+' + re.escape(name) +
                                r'[ \t]+([0-9]+)[ \t]*$',
                                text, re.M)
            if len(definitions) != 1 or values != [version]:
                raise ValueError('FriBidi installed header version differs: ' + name)
        definitions = re.findall(
            r'^[ \t]*#[ \t]*define[ \t]+FRIBIDI_VERSION\b[^\r\n]*$', text, re.M)
        versions = re.findall(
            r'^[ \t]*#[ \t]*define[ \t]+FRIBIDI_VERSION[ \t]+"([^"]+)"[ \t]*$',
                              text, re.M)
        if len(definitions) != 1 or versions != ['1.0.17']:
            raise ValueError('FriBidi installed header version differs')
    elif library == 'libharfbuzz':
        expected = {'HB_VERSION_MAJOR': '15', 'HB_VERSION_MINOR': '0',
                    'HB_VERSION_MICRO': '0'}
        for name, version in expected.items():
            definitions = re.findall(r'^[ \t]*#[ \t]*define[ \t]+' +
                                     re.escape(name) + r'\b[^\r\n]*$', text, re.M)
            values = re.findall(r'^[ \t]*#[ \t]*define[ \t]+' + re.escape(name) +
                                r'[ \t]+([0-9]+)[ \t]*$', text, re.M)
            if len(definitions) != 1 or values != [version]:
                raise ValueError('HarfBuzz installed header version differs: ' + name)
        definitions = re.findall(
            r'^[ \t]*#[ \t]*define[ \t]+HB_VERSION_STRING\b[^\r\n]*$', text, re.M)
        strings = re.findall(
            r'^[ \t]*#[ \t]*define[ \t]+HB_VERSION_STRING[ \t]+"([^"]+)"[ \t]*$',
                             text, re.M)
        if len(definitions) != 1 or strings != ['15.0.0']:
            raise ValueError('HarfBuzz installed header string version differs')


def _bluray_fields(body, label):
    variables, fields = {}, {}
    for raw in _subtitle_text(body, label).splitlines():
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
    config = _subtitle_text(generated['config.h'], 'libbluray config.h')
    _bluray_define(config, 'VERSION', '1.5.0', True)
    for name in ('HAVE_FT2', 'HAVE_LIBXML2', 'HAVE_LIBUDFREAD'):
        _bluray_define(config, name, '1')
    if re.search(r'^[ \t]*#[ \t]*define[ \t]+HAVE_FONTCONFIG\b', config, re.M):
        raise ValueError('libbluray configured fontconfig despite disabled policy')
    _bluray_define(_subtitle_text(generated['contrib/libudfread/config.h'], 'embedded UDF config'), 'HAVE_UDFREAD_VERSION_H', '1')


def _bluray_dependencies(body, work, platform, arch, sdk_root):
    value = _crypto_strict_json(body)
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
            decoded[name] = _subtitle_inline({key: row[key] for key in ('bytes', 'sha256', 'bodyBase64')}, 'bluray dependency ' + name, budget, 4 * 1024 * 1024)
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
    ft_header = _subtitle_text(decoded['freetypeHeader'], 'retained Freetype header')
    for macro in ('FREETYPE_MAJOR', 'FREETYPE_MINOR', 'FREETYPE_PATCH'):
        if len(re.findall(r'^[ \t]*#[ \t]*define[ \t]+' + macro + r'[ \t]+[0-9]{1,3}[ \t]*$', ft_header, re.M)) != 1:
            raise ValueError('libbluray retained Freetype header lacks bounded version macros')
    for kind, macro, include, install_name in (
            ('Libxml', 'LIBXML_DOTTED_VERSION', 'usr/include/libxml2', '/usr/lib/libxml2.2.dylib'),
            ('Zlib', 'ZLIB_VERSION', '', '/usr/lib/libz.1.dylib')):
        header = _subtitle_text(decoded['sdk' + kind + 'Header'], 'SDK version header')
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
        stub = _subtitle_text(decoded['sdk' + kind + 'Stub'], 'SDK linker stub')
        escaped = re.escape(install_name)
        if not stub.startswith('--- !tapi-tbd') or len(re.findall(r'(?m)^install-name:[ \t]+(?:' + escaped + r"|'"+ escaped + r"'|\"" + escaped + r'\")[ \t]*$', stub)) != 1:
            raise ValueError('libbluray selected SDK linker identity differs')
    return decoded




FREETYPE_OPTION_TOKENS = '#ifndef FTOPTION_H_ #define FTOPTION_H_ #include <ft2build.h> FT_BEGIN_HEADER #define FT_CONFIG_OPTION_ENVIRONMENT_PROPERTIES #undef FT_CONFIG_OPTION_FORCE_INT64 #define FT_CONFIG_OPTION_INLINE_MULFIX #define FT_CONFIG_OPTION_USE_LZW #define FT_CONFIG_OPTION_USE_ZLIB #define FT_CONFIG_OPTION_SYSTEM_ZLIB #define FT_CONFIG_OPTION_POSTSCRIPT_NAMES #define FT_CONFIG_OPTION_ADOBE_GLYPH_LIST #define FT_CONFIG_OPTION_MAC_FONTS #ifdef FT_CONFIG_OPTION_MAC_FONTS #define FT_CONFIG_OPTION_GUESSING_EMBEDDED_RFORK #endif #define FT_CONFIG_OPTION_INCREMENTAL #define FT_RENDER_POOL_SIZE 16384L #define FT_MAX_MODULES 32 #undef FT_CONFIG_OPTION_USE_MODULE_ERRORS #define FT_CONFIG_OPTION_SVG #define TT_CONFIG_OPTION_EMBEDDED_BITMAPS #define TT_CONFIG_OPTION_COLOR_LAYERS #define TT_CONFIG_OPTION_POSTSCRIPT_NAMES #define TT_CONFIG_OPTION_SFNT_NAMES #define TT_CONFIG_CMAP_FORMAT_0 #define TT_CONFIG_CMAP_FORMAT_2 #define TT_CONFIG_CMAP_FORMAT_4 #define TT_CONFIG_CMAP_FORMAT_6 #define TT_CONFIG_CMAP_FORMAT_8 #define TT_CONFIG_CMAP_FORMAT_10 #define TT_CONFIG_CMAP_FORMAT_12 #define TT_CONFIG_CMAP_FORMAT_13 #define TT_CONFIG_CMAP_FORMAT_14 #define TT_CONFIG_CMAP_FORMAT_15 #define TT_CONFIG_OPTION_BYTECODE_INTERPRETER #define TT_CONFIG_OPTION_SUBPIXEL_HINTING #undef TT_CONFIG_OPTION_COMPONENT_OFFSET_SCALED #define TT_CONFIG_OPTION_GX_VAR_SUPPORT #define TT_CONFIG_OPTION_VARC #define TT_CONFIG_OPTION_BDF #ifndef TT_CONFIG_OPTION_MAX_RUNNABLE_OPCODES #define TT_CONFIG_OPTION_MAX_RUNNABLE_OPCODES 1000000L #endif #define T1_MAX_DICT_DEPTH 5 #define T1_MAX_SUBRS_CALLS 16 #define T1_MAX_CHARSTRINGS_OPERANDS 256 #undef T1_CONFIG_OPTION_NO_AFM #undef T1_CONFIG_OPTION_NO_MM_SUPPORT #define CFF_CONFIG_OPTION_DARKENING_PARAMETER_X1 500 #define CFF_CONFIG_OPTION_DARKENING_PARAMETER_Y1 400 #define CFF_CONFIG_OPTION_DARKENING_PARAMETER_X2 1000 #define CFF_CONFIG_OPTION_DARKENING_PARAMETER_Y2 275 #define CFF_CONFIG_OPTION_DARKENING_PARAMETER_X3 1667 #define CFF_CONFIG_OPTION_DARKENING_PARAMETER_Y3 275 #define CFF_CONFIG_OPTION_DARKENING_PARAMETER_X4 2333 #define CFF_CONFIG_OPTION_DARKENING_PARAMETER_Y4 0 #define AF_CONFIG_OPTION_CJK #ifdef AF_CONFIG_OPTION_CJK #define AF_CONFIG_OPTION_INDIC #endif #ifdef TT_CONFIG_OPTION_BYTECODE_INTERPRETER #define TT_USE_BYTECODE_INTERPRETER #ifdef TT_CONFIG_OPTION_SUBPIXEL_HINTING #define TT_SUPPORT_SUBPIXEL_HINTING_MINIMAL #endif #endif #ifdef TT_CONFIG_OPTION_COLOR_LAYERS #define TT_SUPPORT_COLRV1 #endif #if CFF_CONFIG_OPTION_DARKENING_PARAMETER_X1 < 0 || \\ CFF_CONFIG_OPTION_DARKENING_PARAMETER_X2 < 0 || \\ CFF_CONFIG_OPTION_DARKENING_PARAMETER_X3 < 0 || \\ CFF_CONFIG_OPTION_DARKENING_PARAMETER_X4 < 0 || \\ \\ CFF_CONFIG_OPTION_DARKENING_PARAMETER_Y1 < 0 || \\ CFF_CONFIG_OPTION_DARKENING_PARAMETER_Y2 < 0 || \\ CFF_CONFIG_OPTION_DARKENING_PARAMETER_Y3 < 0 || \\ CFF_CONFIG_OPTION_DARKENING_PARAMETER_Y4 < 0 || \\ \\ CFF_CONFIG_OPTION_DARKENING_PARAMETER_X1 > \\ CFF_CONFIG_OPTION_DARKENING_PARAMETER_X2 || \\ CFF_CONFIG_OPTION_DARKENING_PARAMETER_X2 > \\ CFF_CONFIG_OPTION_DARKENING_PARAMETER_X3 || \\ CFF_CONFIG_OPTION_DARKENING_PARAMETER_X3 > \\ CFF_CONFIG_OPTION_DARKENING_PARAMETER_X4 || \\ \\ CFF_CONFIG_OPTION_DARKENING_PARAMETER_Y1 > 500 || \\ CFF_CONFIG_OPTION_DARKENING_PARAMETER_Y2 > 500 || \\ CFF_CONFIG_OPTION_DARKENING_PARAMETER_Y3 > 500 || \\ CFF_CONFIG_OPTION_DARKENING_PARAMETER_Y4 > 500 #error "Invalid CFF darkening parameters!" #endif FT_END_HEADER #endif'
FREETYPE_MODULE_HEADER = b'/* This is a generated file. */\nFT_USE_MODULE( FT_Driver_ClassRec, tt_driver_class )\nFT_USE_MODULE( FT_Driver_ClassRec, t1_driver_class )\nFT_USE_MODULE( FT_Driver_ClassRec, cff_driver_class )\nFT_USE_MODULE( FT_Driver_ClassRec, t1cid_driver_class )\nFT_USE_MODULE( FT_Driver_ClassRec, hvf_driver_class )\nFT_USE_MODULE( FT_Driver_ClassRec, pfr_driver_class )\nFT_USE_MODULE( FT_Driver_ClassRec, t42_driver_class )\nFT_USE_MODULE( FT_Driver_ClassRec, winfnt_driver_class )\nFT_USE_MODULE( FT_Driver_ClassRec, pcf_driver_class )\nFT_USE_MODULE( FT_Driver_ClassRec, bdf_driver_class )\nFT_USE_MODULE( FT_Module_Class, sfnt_module_class )\nFT_USE_MODULE( FT_Module_Class, autofit_module_class )\nFT_USE_MODULE( FT_Module_Class, pshinter_module_class )\nFT_USE_MODULE( FT_Renderer_Class, ft_smooth_renderer_class )\nFT_USE_MODULE( FT_Renderer_Class, ft_raster1_renderer_class )\nFT_USE_MODULE( FT_Renderer_Class, ft_svg_renderer_class )\nFT_USE_MODULE( FT_Renderer_Class, ft_sdf_renderer_class )\nFT_USE_MODULE( FT_Renderer_Class, ft_bitmap_sdf_renderer_class )\nFT_USE_MODULE( FT_Module_Class, psaux_module_class )\nFT_USE_MODULE( FT_Module_Class, psnames_module_class )\n/* EOF */\n'

def _freetype_configuration(generated, installed, commands, work, platform, arch, sdk_root):
    option = installed['include/freetype2/freetype/config/ftoption.h']
    modules = installed['include/freetype2/freetype/config/ftmodule.h']
    if option != generated['ftoption.h'] or modules != generated['ftmodule.h'] or modules != FREETYPE_MODULE_HEADER:
        raise ValueError('FreeType generated/installed option/module correspondence differs')
    functional = ' '.join(re.sub(r'/\*.*?\*/', '', _subtitle_text(option, 'FreeType options'), flags=re.S).split())
    if functional != FREETYPE_OPTION_TOKENS:
        raise ValueError('FreeType source-default feature contract differs; systemzlib only enabled integration')
    config = installed['include/freetype2/freetype/config/ftconfig.h']
    if hashlib.sha1(b'blob ' + str(len(config)).encode() + b'\0' + config).hexdigest() != FREETYPE_GIT_FILES['include/freetype/config/ftconfig.h'][1]:
        raise ValueError('FreeType mmapdisabled config header differs from source')
    build = work / 'dist/libfreetype' / platform / 'scratch' / arch
    source = work / 'dist/libfreetype-2.15.0-37515cf5'
    pc = _subtitle_text(generated['vortx-sdk-pkgconfig/zlib.pc'], 'FreeType SDKzlib pc')
    if re.fullmatch(r'Name: zlib\nDescription: Target Apple SDK zlib\nVersion: [0-9]{1,3}(?:\.[0-9]{1,3}){1,3}\nLibs: -lz\nCflags:\n', pc) is None:
        raise ValueError('FreeType generated SDKzlib metadata differs')
    dependencies = _subtitle_json(generated['meson-info/intro-dependencies.json'], 'FreeType dependencies')
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


def _freetype_dependency_paths(work, platform, arch, sdk_root):
    return {'freetypeArchive': 'dist/libfreetype/' + platform + '/thin/' + arch + '/lib/libfreetype.a',
            'sdkZlibHeader': sdk_root + '/usr/include/zlib.h',
            'sdkZlibStub': sdk_root + '/usr/lib/libz.tbd',
            'sdkSettings': sdk_root + '/SDKSettings.json'}


def _freetype_dependency_inputs(value, record, work, platform, arch, sdk_root, budget):
    paths = _freetype_dependency_paths(work, platform, arch, sdk_root)
    if type(value) is not dict or set(value) != set(paths):
        raise ValueError('FreeType archive/SDK input family differs')
    decoded = {}
    for name, path in paths.items():
        row = value[name]
        wanted = {'path','bytes','sha256'} | (set() if name == 'freetypeArchive' else {'bodyBase64'})
        if type(row) is not dict or set(row) != wanted or row['path'] != path or type(row['bytes']) is not int or not 0 < row['bytes'] <= (512*1024*1024 if name == 'freetypeArchive' else 4*1024*1024) or not isinstance(row['sha256'],str) or re.fullmatch(r'[0-9a-f]{64}',row['sha256']) is None:
            raise ValueError('FreeType archive/SDK input wrapper differs')
        if name != 'freetypeArchive':
            decoded[name] = _subtitle_inline({x:row[x] for x in ('bytes','sha256','bodyBase64')}, 'FreeType '+name, budget, 4*1024*1024)
    header = _subtitle_text(decoded['sdkZlibHeader'],'SDKzlib header')
    versions = re.findall(r'(?m)^\s*#\s*define\s+ZLIB_VERSION\s+"([0-9]{1,3}(?:\.[0-9]{1,3}){1,3})"\s*$',header)
    if len(versions) != 1:
        raise ValueError('FreeType SDKzlib version header differs')
    pc_row = record['generatedConfiguration']['vortx-sdk-pkgconfig/zlib.pc']
    pc = _subtitle_inline(pc_row,'FreeType SDKzlib metadata',budget)
    expected = ('Name: zlib\nDescription: Target Apple SDK zlib\nVersion: '+versions[0]+'\nLibs: -lz\nCflags:\n').encode()
    if pc != expected:
        raise ValueError('FreeType generated SDKzlib metadata/header correspondence differs')
    stub = _subtitle_text(decoded['sdkZlibStub'],'SDKzlib stub')
    install_pattern = r"""(?m)^install-name:[ \t]+(?:/usr/lib/libz\.1\.dylib|'/usr/lib/libz\.1\.dylib'|"/usr/lib/libz\.1\.dylib")[ \t]*$"""
    if (not stub.startswith('--- !tapi-tbd') or len(re.findall(r'(?m)^install-name:[^\r\n]*$',stub)) != 1
            or len(re.findall(install_pattern,stub)) != 1):
        raise ValueError('FreeType selected SDKzlib linker identity differs')
    settings = _subtitle_json(decoded['sdkSettings'],'FreeType SDKSettings')
    if type(settings) is not dict or not isinstance(settings.get('Version'),str) or re.fullmatch(r'[0-9]{1,3}(?:\.[0-9]{1,3}){0,3}',settings['Version']) is None:
        raise ValueError('FreeType selected SDKSettings identity differs')
    return decoded

def _subtitle_record_contract(record, work, library, platform, arch, budget):
    expected_keys = {'schema', 'library', 'selector', 'route', 'platform', 'arch',
                     'sourceDirectory', 'buildDirectory', 'prefix', 'arguments',
                     'environment', 'makeArguments', 'generatedConfiguration',
                     'installedIdentity', 'compiled', 'installed'}
    if type(record) is not dict or set(record) != expected_keys:
        raise ValueError('subtitle build record keys differ from the Swift producer')
    source = work / 'dist' / (library + '-' + SUBTITLE_SELECTORS[library])
    build = work / 'dist' / library / platform / 'scratch' / arch
    prefix = work / 'dist' / library / platform / 'thin' / arch
    _, _, _, host, _, _, _ = _subtitle_platform(platform, arch)
    arguments = (('--host=' + host, '--with-pic', '--enable-static', '--disable-shared')
                 if library == 'libunibreak' else SUBTITLE_ARGUMENTS[library])
    fixed = {'schema': 1, 'library': library, 'selector': SUBTITLE_SELECTORS[library],
             'route': SUBTITLE_ROUTES[library], 'platform': platform, 'arch': arch,
             'sourceDirectory': str(source), 'buildDirectory': str(build),
             'prefix': str(prefix), 'arguments': list(arguments),
             'makeArguments': (list(SUBTITLE_MAKE_ARGUMENTS)
                               if library == 'libunibreak' else []),
             'compiled': True, 'installed': True}
    if any(not _crypto_exact_equal(record[name], item) for name, item in fixed.items()):
        raise ValueError('subtitle build record identity/options differ from fixed policy')
    sdk_root, cflags, ldflags = _subtitle_environment(
        record['environment'], work, library, platform, arch)
    generated_names = set(SUBTITLE_GENERATED[library])
    if library == 'libunibreak' and 'config.h' in record['generatedConfiguration']:
        generated_names.add('config.h')
    if (type(record['generatedConfiguration']) is not dict
            or set(record['generatedConfiguration']) != generated_names
            or type(record['installedIdentity']) is not dict
            or set(record['installedIdentity']) != set(SUBTITLE_INSTALLED[library])):
        raise ValueError('subtitle generated/installed file set differs')
    before = budget[0]
    generated = {name: _subtitle_inline(record['generatedConfiguration'][name],
                                         library + '/' + name, budget)
                 for name in sorted(generated_names)}
    installed = {name: _subtitle_inline(record['installedIdentity'][name],
                                         library + '/' + name, budget)
                 for name in SUBTITLE_INSTALLED[library]}
    if budget[0] - before > SUBTITLE_MAX_RECORD_BODIES:
        raise ValueError('subtitle per-record nested raw-body cap exceeded')
    if library == 'libunibreak':
        makefile = _subtitle_text(generated['Makefile'], 'libunibreak Makefile')
        logs = (_subtitle_text(generated['config.status'], 'libunibreak config.status') + '\n' +
                _subtitle_text(generated['config.log'], 'libunibreak config.log'))
        assignments = {
            'CC': record['environment']['CC'], 'CFLAGS': record['environment']['CFLAGS'],
            'CPPFLAGS': cflags, 'LDFLAGS': ldflags,
            'PACKAGE_VERSION': '8.0', 'prefix': str(prefix),
        }
        for name, expected in assignments.items():
            modifier_lines = re.findall(
                r'^[ \t]*(?:(?:override|export|private|unexport)[ \t]+)+' +
                re.escape(name) + r'\b[^\r\n]*$', makefile, re.M)
            assignment_lines = re.findall(
                r'^[ \t]*' + re.escape(name) +
                r'[ \t]*(?:::=|::=|:=|\+=|\?=|!=|=)[^\r\n]*$',
                makefile, re.M)
            values = re.findall(r'^[ \t]*' + re.escape(name) +
                                r'[ \t]*=[ \t]*([^\r\n]*?)[ \t]*$',
                                makefile, re.M)
            if modifier_lines or len(assignment_lines) != 1 or values != [expected]:
                raise ValueError('libunibreak generated Makefile assignment differs: ' + name)
        if any(argument not in logs for argument in arguments):
            raise ValueError('libunibreak generated configuration differs from fixed release options')
        if 'config.h' in generated:
            _subtitle_text(generated['config.h'], 'libunibreak config.h')
    else:
        _subtitle_meson_cross(generated['crossFile.meson'], work, library, platform,
                              arch, sdk_root, cflags, ldflags)
        ninja = _subtitle_text(generated['build.ninja'], library + ' build.ninja')
        if ('ninja_required_version' not in ninja
                or re.search(r'(?i)(?:^|[\s=])(curl|wget)(?:\s|$)|git\s+clone|wrapdb', ninja)):
            raise ValueError('subtitle Ninja file is missing identity or contains a fetch route')
        commands = _subtitle_json(generated['compile_commands.json'], 'compile commands')
        if type(commands) is not list or not commands or len(commands) > 100000:
            raise ValueError('subtitle compile command set is empty or unbounded')
        _, target, minimum, _, _, _, _ = _subtitle_platform(platform, arch)
        if library == 'libfribidi':
            _subtitle_fribidi_compile_commands(commands, build, arch, sdk_root, target, minimum)
        else:
            for command in commands:
                _subtitle_compile_command(command, arch, sdk_root, target, minimum)
        _subtitle_build_options(generated['meson-info/intro-buildoptions.json'],
                                library, prefix)
        if library == 'libbluray':
            _bluray_config(generated)
            _bluray_dependencies(generated['meson-info/intro-dependencies.json'], work, platform, arch, sdk_root)
            source = str(work / 'dist/libbluray-1.5.0-f676408e') + '/'
            udf = False
            for command in commands:
                if (command.get('directory') != str(build) or not isinstance(command.get('file'), str)
                        or not isinstance(command.get('output'), str)):
                    raise ValueError('libbluray compile directory/source identity differs')
                name = os.path.normpath(os.path.join(str(build), command['file']))
                if not name.startswith(source) or not name.endswith('.c'):
                    raise ValueError('libbluray compile source escapes its admitted archive')
                if not os.path.normpath(os.path.join(str(build), command['output'])).startswith(str(build) + '/'):
                    raise ValueError('libbluray compile output escapes its admitted build')
                _subtitle_compile_command(command, arch, sdk_root, target, minimum,
                                          (command['file'], command['output'], False))
                udf |= '/contrib/libudfread/src/' in name
            if not udf:
                raise ValueError('libbluray compile evidence lacks embedded UDF sources')
        elif library == 'libfreetype':
            _freetype_configuration(generated, installed, commands, work, platform, arch, sdk_root)
        else:
            _subtitle_dependencies(generated['meson-info/intro-dependencies.json'])
    if library == 'libfreetype':
        _subtitle_header(installed[SUBTITLE_INSTALLED[library][0]], library)
        _subtitle_pc(installed[SUBTITLE_INSTALLED[library][-1]], library, prefix)
        return record
    header_name, pc_name = SUBTITLE_INSTALLED[library]
    _subtitle_header(installed[header_name], library)
    _subtitle_pc(installed[pc_name], library, prefix)
    return record


def _subtitle_release_boundary(work):
    state = work / 'dist' / 'subtitle-sources-v4'
    archive_directory = state / 'archives'
    if (state.is_symlink() or not state.is_dir() or state.resolve() != state.absolute()
            or archive_directory.is_symlink() or not archive_directory.is_dir()
            or archive_directory.resolve() != archive_directory.absolute()
            or {path.name for path in state.iterdir()} != {'archives', 'receipt.json'}
            or {path.name for path in archive_directory.iterdir()} !=
            {pin['filename'] for pin in SUBTITLE_SOURCE_OUTPUTS}):
        raise ValueError('subtitle release-source state is not the exact helper output')
    verified = []
    for pin in SUBTITLE_SOURCE_OUTPUTS:
        body = _crypto_read_regular(archive_directory / pin['filename'], pin['maximumBytes'])
        verified.append((pin, body, _crypto_index_archive(pin, body, True)))
    expected = _crypto_expected_receipt(
        verified, SUBTITLE_SOURCE_PROFILE,
        'fixed-sha256-from-upstream-release-metadata-maintained-android-pin-or-official-sidecar; fixed-apple-source-transforms; official-freetype-git-membership-empty-dlg-v1', 3)
    receipt_path = state / 'receipt.json'
    body = _crypto_read_regular(receipt_path, CRYPTO_MAX_RECEIPT)
    if (not _crypto_exact_equal(_crypto_strict_json(body), expected)
            or body != _crypto_canonical(expected)):
        raise ValueError('subtitle helper receipt differs from retained raw archives')
    return {'path': 'dist/subtitle-sources-v4/receipt.json', 'bytes': len(body),
            'sha256': hashlib.sha256(body).hexdigest()}


def _subtitle_record_row(work, library, platform, arch, budget):
    path = (work / 'dist' / library / platform / 'scratch' / arch /
            'vortx-subtitle-build.json')
    body = _crypto_read_regular(path, SUBTITLE_MAX_RECORD)
    budget[0] += len(body)
    if budget[0] > SUBTITLE_MAX_INLINE_RAW:
        raise ValueError('subtitle aggregate raw-body cap exceeded')
    record = _subtitle_json(body, 'build record')
    _subtitle_record_contract(record, work, library, platform, arch, budget)
    return {'path': path.relative_to(work).as_posix(), 'bytes': len(body),
            'sha256': hashlib.sha256(body).hexdigest(),
            'bodyBase64': base64.b64encode(body).decode('ascii')}


def _bluray_observe_inputs(work, platform, arch, budget):
    record_path = work / 'dist/libbluray' / platform / 'scratch' / arch / 'vortx-subtitle-build.json'
    record = _subtitle_json(_crypto_read_regular(record_path, SUBTITLE_MAX_RECORD), 'bluray dependency record')
    sdk_root, _, _ = _subtitle_environment(record['environment'], work, 'libbluray', platform, arch)
    result = {}
    for name, relative in _bluray_dependency_paths(work, platform, arch, sdk_root).items():
        path = Path(relative) if relative.startswith('/') else work / relative
        if name.startswith('sdk') and name not in ('sdkLibxmlPC', 'sdkZlibPC'):
            sdk = Path(sdk_root).resolve()
            path = path.resolve()
            if sdk not in path.parents:
                raise ValueError('libbluray SDK dependency escaped the selected SDK')
        body = _crypto_read_regular(path, 512 * 1024 * 1024 if name == 'freetypeArchive' else 4 * 1024 * 1024)
        result[name] = {'path': relative, 'bytes': len(body), 'sha256': hashlib.sha256(body).hexdigest()}
        if name != 'freetypeArchive':
            result[name]['bodyBase64'] = base64.b64encode(body).decode('ascii')
    _bluray_dependency_inputs(result, work, platform, arch, sdk_root, budget)
    return result


def _freetype_observe_inputs(work, platform, arch, budget):
    record = _subtitle_json(_crypto_read_regular(work / 'dist/libfreetype' / platform / 'scratch' / arch / 'vortx-subtitle-build.json', SUBTITLE_MAX_RECORD), 'FT record')
    sdk_root, _, _ = _subtitle_environment(record['environment'], work, 'libfreetype', platform, arch)
    result = {}
    for name, relative in _freetype_dependency_paths(work, platform, arch, sdk_root).items():
        path = Path(relative) if relative.startswith('/') else work / relative
        if name.startswith('sdk') and name not in ('sdkLibxmlPC', 'sdkZlibPC'):
            sdk = Path(sdk_root).resolve()
            path = path.resolve()
            if sdk not in path.parents:
                raise ValueError('FreeType SDK dependency escaped the selected SDK')
        body = _crypto_read_regular(path,512*1024*1024 if name == 'freetypeArchive' else 4*1024*1024)
        row = {'path':relative,'bytes':len(body),'sha256':hashlib.sha256(body).hexdigest()}
        if name != 'freetypeArchive': row['bodyBase64'] = base64.b64encode(body).decode('ascii')
        result[name] = row
    _freetype_dependency_inputs(result,record,work,platform,arch,sdk_root,budget)
    return result


def _freetype_require_composition():
    # Presence is an interface check only; the root-sealed recipe and separate
    # DoviBOM/catalog validators establish real joint content acceptance.
    if globals().get('DOVI_SOURCE_PROFILE') != 'native-upgrades-libdovi340-v1' or globals().get('DOVI_SOURCE_VERSION') != '3.4.0':
        raise ValueError('Unsealed FT/Dovi composition: exact Dovi source policy interface is missing')


def _subtitle_receipt_shape(value, body, work):
    _freetype_require_composition()
    expected_keys = {'schemaVersion', 'profile', 'sourceProfile', 'versions', 'selectors',
                     'releaseSourceBoundary', 'rows', 'retainedLibassCompatibility',
                     'retainedBlurayCompatibility', 'retainedFreetypeAuthentication',
                     'sourceFreetypeAuthentication', 'runtimeSecurityTested', 'promotionEligible'}
    if type(value) is not dict or set(value) != expected_keys:
        raise ValueError('subtitle BOM keys differ from schema 1')
    fixed = {'schemaVersion': 1, 'profile': NATIVE_UPGRADES_PROFILE,
             'sourceProfile': SUBTITLE_SOURCE_PROFILE, 'versions': SUBTITLE_VERSIONS,
             'selectors': SUBTITLE_SELECTORS, 'retainedLibassCompatibility': 'HOLD',
             'retainedBlurayCompatibility': 'HOLD', 'retainedFreetypeAuthentication': 'HOLD',
             'sourceFreetypeAuthentication': 'SOURCE_AND_COMPILER_BOUND',
             'runtimeSecurityTested': False, 'promotionEligible': False}
    if any(not _crypto_exact_equal(value[name], item) for name, item in fixed.items()):
        raise ValueError('subtitle BOM identity or open-gate status differs')
    if not _crypto_exact_equal(value['releaseSourceBoundary'],
                               _subtitle_release_boundary(work)):
        raise ValueError('subtitle BOM/source-helper raw receipt correspondence')
    if type(value['rows']) is not list or len(value['rows']) != len(SUBTITLE_MATRIX):
        raise ValueError('subtitle BOM must contain the exact nine-row matrix')
    budget = [0]
    observed = []
    for row, identity in zip(value['rows'], SUBTITLE_MATRIX, strict=True):
        if type(row) is not dict or set(row) != {'platform', 'arch', 'slice', 'builds'}:
            raise ValueError('subtitle BOM matrix row shape differs')
        platform, arch, slice_name = identity
        if not _crypto_exact_equal(
                {name: row[name] for name in ('platform', 'arch', 'slice')},
                {'platform': platform, 'arch': arch, 'slice': slice_name}):
            raise ValueError('subtitle BOM matrix order or identity differs')
        builds = row['builds']
        if type(builds) is not dict or set(builds) != set(SUBTITLE_VERSIONS):
            raise ValueError('subtitle BOM build family differs')
        for library in SUBTITLE_VERSIONS:
            build = builds[library]
            if type(build) is not dict or set(build) != ({'record', 'dependencyInputs'} if library in ('libbluray','libfreetype') else {'record'}):
                raise ValueError('subtitle BOM build row differs')
            record_row = build['record']
            if (type(record_row) is not dict
                    or set(record_row) != {'path', 'bytes', 'sha256', 'bodyBase64'}
                    or record_row['path'] != ('dist/' + library + '/' + platform +
                                              '/scratch/' + arch +
                                              '/vortx-subtitle-build.json')
                    or type(record_row['bytes']) is not int
                    or not 0 < record_row['bytes'] <= SUBTITLE_MAX_RECORD
                    or not re.fullmatch(r'[0-9a-f]{64}', record_row['sha256'])
                    or not isinstance(record_row['bodyBase64'], str)):
                raise ValueError('subtitle BOM record wrapper differs')
            record_body = _subtitle_inline(
                {name: record_row[name]
                 for name in ('bytes', 'sha256', 'bodyBase64')},
                'BOM build record', budget, SUBTITLE_MAX_RECORD)
            record = _subtitle_json(record_body, 'BOM build record')
            _subtitle_record_contract(record, work, library, platform, arch, budget)
            if library == 'libbluray':
                sdk_root, _, _ = _subtitle_environment(record['environment'], work, library, platform, arch)
                _bluray_dependency_inputs(build['dependencyInputs'], work, platform, arch, sdk_root, budget)
            elif library == 'libfreetype':
                sdk_root, _, _ = _subtitle_environment(record['environment'], work, library, platform, arch)
                _freetype_dependency_inputs(build['dependencyInputs'], record, work, platform, arch, sdk_root, budget)
        if 'libfreetype' in builds:
            if not _crypto_exact_equal(builds['libbluray']['dependencyInputs']['freetypeArchive'], builds['libfreetype']['dependencyInputs']['freetypeArchive']):
                raise ValueError('Bluray did not bind the same freshly built FT archive')
            ft_record = _subtitle_json(_subtitle_inline({k:builds['libfreetype']['record'][k] for k in ('bytes','sha256','bodyBase64')}, 'FT provider record', budget, SUBTITLE_MAX_RECORD), 'FT provider record')
            for name, installed_name in [('freetypeHeader',SUBTITLE_INSTALLED['libfreetype'][0]),('freetypePC',SUBTITLE_INSTALLED['libfreetype'][-1])]:
                if {k:builds['libbluray']['dependencyInputs'][name][k] for k in ('bytes','sha256','bodyBase64')} != ft_record['installedIdentity'][installed_name]:
                    raise ValueError('Bluray FT header/PC is not the new source-built provider')
        observed.append(identity)
    if observed != list(SUBTITLE_MATRIX):
        raise ValueError('subtitle BOM matrix coverage differs')
    canonical = (json.dumps(value, indent=2, sort_keys=True) + '\n').encode('utf-8')
    if body != canonical or len(body) > SUBTITLE_MAX_RECEIPT:
        raise ValueError('subtitle BOM is not canonical or exceeds its final bound')
    return value


def apple_subtitle_builds(work):
    _freetype_require_composition()
    """Capture all 45 authenticated subtitle/bluray/FreeType build records and raw bodies."""
    work = work.absolute()
    if work.is_symlink() or not work.is_dir() or work.resolve() != work:
        raise ValueError('subtitle WORK must be a real absolute directory')
    release_boundary = _subtitle_release_boundary(work)
    budget = [0]
    rows = []
    for platform, arch, slice_name in SUBTITLE_MATRIX:
        builds = {}
        for library in SUBTITLE_VERSIONS:
            builds[library] = {'record': _subtitle_record_row(
                work, library, platform, arch, budget)}
            if library == 'libbluray':
                builds[library]['dependencyInputs'] = _bluray_observe_inputs(work, platform, arch, budget)
            elif library == 'libfreetype':
                builds[library]['dependencyInputs'] = _freetype_observe_inputs(work, platform, arch, budget)
        rows.append({'platform': platform, 'arch': arch, 'slice': slice_name,
                     'builds': builds})
    destination_root = work / 'dist' / 'subtitle-builds'
    if destination_root.exists() or destination_root.is_symlink():
        raise ValueError('subtitle BOM destination must be fresh')
    destination_root.mkdir(mode=0o755)
    receipt = {'schemaVersion': 1, 'profile': NATIVE_UPGRADES_PROFILE,
               'sourceProfile': SUBTITLE_SOURCE_PROFILE,
               'versions': SUBTITLE_VERSIONS, 'selectors': SUBTITLE_SELECTORS,
               'releaseSourceBoundary': release_boundary, 'rows': rows,
               'retainedLibassCompatibility': 'HOLD',
               'retainedBlurayCompatibility': 'HOLD', 'retainedFreetypeAuthentication': 'HOLD',
               'sourceFreetypeAuthentication': 'SOURCE_AND_COMPILER_BOUND',
               'runtimeSecurityTested': False, 'promotionEligible': False}
    encoded = (json.dumps(receipt, indent=2, sort_keys=True) + '\n').encode('utf-8')
    if len(encoded) > SUBTITLE_MAX_RECEIPT:
        raise ValueError('subtitle BOM exceeds its final bound')
    destination = destination_root / 'vortx-subtitle-builds.json'
    destination.write_bytes(encoded)
    print('PASS subtitle-profile ' + SUBTITLE_SOURCE_PROFILE)
    print('PASS apple-subtitle-builds')


def apple_subtitle_receipt(receipt_path):
    """Revalidate the canonical subtitle BOM against all current raw records."""
    receipt_path = receipt_path.absolute()
    if (receipt_path.is_symlink() or receipt_path.resolve() != receipt_path
            or receipt_path.name != 'vortx-subtitle-builds.json'
            or receipt_path.parent.name != 'subtitle-builds'
            or receipt_path.parent.parent.name != 'dist'):
        raise ValueError('subtitle receipt must be the exact generated BOM file')
    work = receipt_path.parent.parent.parent
    body = _crypto_read_regular(receipt_path, SUBTITLE_MAX_RECEIPT)
    value = _subtitle_receipt_shape(_subtitle_json(body, 'BOM'), body, work)
    rows = {(row['platform'], row['arch']): row for row in value['rows']}
    budget = [0]
    for platform, arch, _ in SUBTITLE_MATRIX:
        for library in SUBTITLE_VERSIONS:
            observed = _subtitle_record_row(work, library, platform, arch, budget)
            expected = rows[(platform, arch)]['builds'][library]['record']
            if not _crypto_exact_equal(observed, expected):
                raise ValueError('subtitle build record changed after BOM capture')
            if library == 'libbluray' and not _crypto_exact_equal(
                    _bluray_observe_inputs(work, platform, arch, budget), rows[(platform, arch)]['builds'][library]['dependencyInputs']):
                raise ValueError('libbluray dependency inputs changed after BOM capture')
            if library == 'libfreetype' and not _crypto_exact_equal(_freetype_observe_inputs(work, platform, arch, budget), rows[(platform,arch)]['builds'][library]['dependencyInputs']):
                raise ValueError('FreeType archive/SDK inputs changed after capture')
    print('PASS subtitle-profile ' + SUBTITLE_SOURCE_PROFILE)
    print('PASS apple-subtitle-receipt')


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

def _dovi_file(path, logical, maximum=16*1024**2):
    info=path.lstat()
    dv_need(stat.S_ISREG(info.st_mode) and not path.is_symlink() and 0<info.st_size<=maximum,'real bounded input '+logical)
    body=path.read_bytes(); dv_need(len(body)==info.st_size,'input changed while reading')
    return {'path':logical,'bytes':len(body),'sha256':dv_hash(body),'bodyBase64':base64.b64encode(body).decode('ascii')}


def _dovi_observe(work):
    dv_require_composition()
    work=work.absolute(); dv_need(work.resolve()==work and work.is_dir() and not work.is_symlink(),'real WORK')
    root=work/'dist/dovi-inputs'; policy_path=work/'Sources/BuildScripts/dovi-source-policy.json'
    policy_body=policy_path.read_bytes(); dv_need(dv_hash(policy_body)==DOVI_POLICY_SHA,'fixed source/API policy')
    policy=dv_json(policy_body); pins_body=(root/'inputs.json').read_bytes(); pins=dv_json(pins_body)
    dv_need(pins.get('admissionReceiptPath')==str(root/'admission.json') and
            pins.get('vendorRoot')==str(root/'vendor') and pins.get('cargoCRoot')==str(root/'cargo-c-install'),'fixed owned input roots before reading providers')
    input_files={
       'inputs':(root/'inputs.json','dovi-inputs/inputs.json'),
       'admission':(Path(pins['admissionReceiptPath']),'dovi-inputs/admission.json'),
       'sourceMap':(work/'Sources/BuildScripts/dovi-source-map.json','dovi-inputs/source-map.json'),
       'libraryLock':(work/'dist'/DOVI_SOURCE_ROOT/'dolby_vision/Cargo.lock','dovi-inputs/library-Cargo.lock'),
       'stdLock':(Path(pins['toolchainRoot'])/'lib/rustlib/src/rust/library/Cargo.lock','dovi-inputs/std-Cargo.lock'),
       'cargoCSource':(root/'cargo-c-0.10.26+cargo-0.100.0.crate','dovi-inputs/cargo-c.crate'),
       'cargoCPackageLock':(root/'cargo-c-Cargo.lock','dovi-inputs/cargo-c-Cargo.lock'),
       'vendorIndex':(root/'vendor-index.json','dovi-inputs/vendor-index.json'),
       'hostToolBuild':(root/'cargo-c-build.json','dovi-inputs/cargo-c-build.json'),
       'hostToolOperator':(root/'cargo-c-host-operator.py','dovi-inputs/cargo-c-host-operator.py'),
       'bootstrapInputs':(root/'bootstrap-inputs.json','dovi-inputs/bootstrap-inputs.json'),
       'bootstrapAdmission':(root/'bootstrap-admission.json','dovi-inputs/bootstrap-admission.json')}
    source_inputs={name:_dovi_file(path,logical,64*1024**2) for name,(path,logical) in input_files.items()}
    budget=[0]; inputs,mapping,vendor,bodies=dv_inputs(source_inputs,budget,work)
    sdk_inputs={}
    for sdk_name,sdk in inputs['sdks'].items():
        sdk_root=Path(sdk['resolvedRoot']); dv_need(sdk_root.resolve()==sdk_root and Path(sdk['selectedRoot']).resolve()==sdk_root,'real selected SDK')
        sdk_inputs[sdk_name]={}
        for item in sdk['files']:
            selected=sdk_root/item['path']; resolved=selected.resolve()
            dv_need(resolved.is_relative_to(sdk_root),'SDK provider escaped canonical root')
            sdk_inputs[sdk_name][item['path']]=_dovi_file(resolved,'sdk/'+sdk_name+'/'+item['path'],4*1024**2)
    dv_sdk(inputs,sdk_inputs,budget)
    vendor_tar=(root/'vendor-crates.tar').read_bytes(); dv_vendor_binding(vendor_tar,vendor,inputs)
    dv_need(dv_json(bodies['hostToolBuild'])['vendorCaptureSHA256']==dv_hash(vendor_tar),'actual host/current vendor capture conservation')
    source_files=[]
    for item in mapping['blobs']:
        path=work/'dist'/DOVI_SOURCE_ROOT/item['path']; raw=path.read_bytes()
        oid=hashlib.sha1(b'blob '+str(len(raw)).encode()+b'\0'+raw).hexdigest()
        dv_need(path.is_file() and not path.is_symlink() and len(raw)==item['size'] and oid==item['sha'] and not path.stat().st_mode&0o111,'actual official source file')
        source_files.append({'path':item['path'],'bytes':len(raw),'sha256':dv_hash(raw),'gitBlobSHA1':oid})
    policy=dict(policy,inputsSHA256=dv_hash(pins_body)); rows=[]
    for identity in DOVI_MATRIX:
        platform,arch,_,sdk_name,_,floor,_,slice_name,platform_id=identity
        scratch=work/'dist/libdovi'/platform/'scratch'/arch; prefix=work/'dist/libdovi'/platform/'thin'/arch
        row={'platform':platform,'arch':arch,'slice':slice_name}
        files={'record':scratch/'vortx-dovi-build.json','header':prefix/'include/libdovi/rpu_parser.h','pkgConfig':prefix/'lib/pkgconfig/dovi.pc',
          'cargoLog':scratch/'cargo-cinstall.log','abiSource':scratch/'dovi-api-abi.c','abiObject':scratch/'dovi-api-abi.o',
          'consumerRecord':work/'dist/libplacebo'/platform/'scratch'/arch/'vortx-dovi-consumer.json',
          'consumerDependencies':work/'dist/libplacebo'/platform/'scratch'/arch/'meson-info/intro-dependencies.json'}
        for name,path in files.items(): row[name]=_dovi_file(path,path.relative_to(work).as_posix())
        consumer_archive=work/'dist/libplacebo'/platform/'thin'/arch/'lib/libplacebo.a'
        consumer_bytes=consumer_archive.read_bytes()
        row['consumerArchive']={'path':consumer_archive.relative_to(work).as_posix(),'bytes':len(consumer_bytes),'sha256':dv_hash(consumer_bytes)}
        archive_path=prefix/'lib/libdovi.a'; archive_body=archive_path.read_bytes(); sdk=inputs['sdks'][sdk_name]
        row['archive']={'path':archive_path.relative_to(work).as_posix(),'bytes':len(archive_body),'sha256':dv_hash(archive_body),
          'inspection':dv_archive(archive_body,arch,platform_id,dv_version(floor),dv_version(sdk['version']),policy['requiredSymbols'])}
        dv_row(row,inputs,policy,work,identity,budget,archive_body); rows.append(row)
        consumer_objects=dv_archive(consumer_bytes,arch,platform_id,dv_version(floor),dv_version(sdk['version']),())
        dv_need(all(not (set(member['object']['defined']) & set(policy['requiredSymbols'])) for member in consumer_objects['members']),
                'libplacebo embeds another dovi C API provider')
    return {'schemaVersion':1,'profile':DOVI_PROFILE,'sourceProfile':DOVI_SOURCE_PROFILE,'version':'3.4.0','work':str(work),
      'sourceCommit':DOVI_SOURCE_COMMIT,'sourceInputs':source_inputs,'sdkInputs':sdk_inputs,'sourceFiles':source_files,
      'policy':_dovi_file(policy_path,'dovi-inputs/source-policy.json'),
      'vendorCapture':{'path':'dist/dovi-inputs/vendor-crates.tar','bytes':len(vendor_tar),'sha256':dv_hash(vendor_tar)},
      'rows':rows,'runtimeDolbyVisionTested':False,'promotionEligible':False}


def apple_dovi_builds(work):
    value=_dovi_observe(work); destination=work/'dist/dovi-builds'
    dv_need(not destination.exists() and not destination.is_symlink(),'fresh build receipt destination')
    destination.mkdir(mode=0o755); body=(json.dumps(value,indent=2,sort_keys=True)+'\n').encode()
    dv_need(len(body)<=DOVI_LIMIT,'final build receipt cap'); (destination/'vortx-dovi-builds.json').write_bytes(body)
    print('PASS dovi-profile '+DOVI_SOURCE_PROFILE); print('PASS apple-dovi-builds')


def apple_dovi_receipt(path):
    path=path.absolute(); dv_need(path.resolve()==path and path.name=='vortx-dovi-builds.json' and path.parent.name=='dovi-builds' and path.parent.parent.name=='dist','fixed receipt location')
    observed=_dovi_observe(path.parent.parent.parent); body=path.read_bytes()
    dv_need(body==(json.dumps(observed,indent=2,sort_keys=True)+'\n').encode(),'actual source/build/provider receipt correspondence')
    print('PASS dovi-profile '+DOVI_SOURCE_PROFILE); print('PASS apple-dovi-receipt')


def relro_16k_safe(row, loads):
    # Android also permits an unaligned RELRO end when it occupies its entire LOAD,
    # with no other LOAD data inside the page-rounded protection range. Do not
    # mistake NDK/LLD's isolated RELRO layout for writable data sharing that page.
    # https://developer.android.com/guide/practices/page-sizes (Check the RELRO security flag)
    offset, start, file_size, memory_size = (int(row[i], 16) for i in (1, 2, 4, 5))
    end = start + memory_size
    if end % 16384 == 0:
        return True
    if memory_size <= 0:
        return False
    owners = [index for index, load in enumerate(loads)
              if tuple(int(load[i], 16) for i in (1, 2, 4, 5)) ==
              (offset, start, file_size, memory_size)]
    if len(owners) != 1:
        return False
    protected_start = start // 16384 * 16384
    protected_end = (end + 16383) // 16384 * 16384
    for index, load in enumerate(loads):
        if index == owners[0]:
            continue
        other_start, other_size = int(load[2], 16), int(load[5], 16)
        if other_size and other_start < protected_end and other_start + other_size > protected_start:
            return False
    return True


SENT_FFMPEG_FUNCTIONS = (
    'avpriv_vortx_http_copy_sent_request_v2', 'avpriv_vortx_http_sent_request_clear_v2')
REFERENCE_FFMPEG_FUNCTIONS = (
    'avpriv_vortx_reference_capture_v1', 'avpriv_vortx_reference_revalidate_v1',
    'avpriv_vortx_reference_recipe_current', 'avpriv_vortx_reference_open_prefix_v1',
    'avpriv_vortx_reference_read_v1', 'avpriv_vortx_reference_stats_v1',
    'avpriv_vortx_reference_reader_close_v1', 'avpriv_vortx_reference_recipe_release_v1',
    'avpriv_vortx_reference_sparse_budget_create_v1',
    'avpriv_vortx_reference_sparse_budget_info_v1',
    'avpriv_vortx_reference_sparse_open_v1',
    'avpriv_vortx_reference_sparse_next_part_v1',
    'avpriv_vortx_reference_sparse_read_part_v1',
    'avpriv_vortx_reference_sparse_stats_v1',
    'avpriv_vortx_reference_sparse_close_v1',
    'avpriv_vortx_reference_sparse_budget_release_v1')
RETIRED_SENT_FFMPEG_FUNCTIONS = (
    'avpriv_vortx_http_copy_sent_request', 'avpriv_vortx_http_sent_request_clear')
PRIVATE_MPV_FUNCTIONS = ('stream_reference_sent_request_copy_transport',)
SENT_MPV_FUNCTIONS = (
    'stream_reference_source_observe_sent_request',
    'stream_reference_source_revalidate_sent_request',
    'stream_reference_sent_request_cancelled',
    'stream_reference_sent_request_copy_values',
    'stream_reference_sent_request_values_clear', 'stream_reference_sent_request_release',
    'stream_reference_source_prepare_prefix_request',
    'stream_reference_sent_request_copy_transport')


def required_elf_functions(text, required, role, forbidden=()):
    """Require one real .dynsym GLOBAL DEFAULT FUNC per exact normalized name."""
    if role not in ('defined-provider', 'undefined-import') or not required or len(set(required)) != len(required):
        raise ValueError('invalid required ELF function contract')
    if not isinstance(text, str) or '\0' in text or len(text) > 16 * 1024**2:
        raise ValueError('invalid or oversized dynamic symbol text')
    lines = text.splitlines()
    if len(lines) > 200000 or any(len(line) > 16384 for line in lines):
        raise ValueError('oversized dynamic symbol table')
    header = [re.fullmatch(r"Symbol table '\.dynsym' contains ([0-9]+) entries:", line.strip())
              for line in lines if line.strip().startswith('Symbol table ')]
    if len(header) != 1 or header[0] is None:
        raise ValueError('expected exactly one complete .dynsym table')
    count = int(header[0].group(1))
    if count < 1 or count > 200000:
        raise ValueError('invalid dynamic symbol count')
    rows, found = set(), {}
    pattern = re.compile(r'\s*([0-9]+):\s+([0-9a-fA-F]+)\s+([0-9]+)\s+'
                         r'(\S+)\s+(\S+)\s+(\S+)\s+(\S+)(?:\s+(\S+)(?:\s+\([0-9]+\))?)?\s*')
    for line in lines:
        if not re.match(r'\s*[0-9]+:', line):
            continue
        row = pattern.fullmatch(line)
        if not row or len(row.group(2)) > 16:
            raise ValueError('malformed dynamic symbol row')
        index, value, size, kind, binding, visibility, section, raw = row.groups()
        index = int(index)
        if index >= count or index in rows:
            raise ValueError('duplicate or out-of-range dynamic symbol index')
        rows.add(index)
        if raw and raw.split('@', 1)[0] in forbidden:
            raise ValueError('retired ELF bridge symbol: ' + raw)
        if not raw or raw.split('@', 1)[0] not in required:
            continue
        name = re.fullmatch(r'([A-Za-z_][A-Za-z0-9_]*)(?:(@@?)([A-Za-z_][A-Za-z0-9_.-]{0,127}))?', raw)
        if not name or len(raw) > 384:
            raise ValueError('malformed required versioned ELF name')
        base, version_kind, version = name.groups()
        if base in found or kind != 'FUNC' or binding != 'GLOBAL' or visibility != 'DEFAULT':
            raise ValueError('duplicate, weak, non-function or hidden required ELF symbol: ' + base)
        defined = re.fullmatch(r'[0-9]+', section) is not None and int(section) > 0
        if (role == 'defined-provider' and not defined) or (role == 'undefined-import' and section != 'UND'):
            raise ValueError('wrong required ELF function role: ' + base)
        found[base] = {'name': base, 'version': version, 'defaultVersion': version_kind == '@@',
                       'type': kind, 'binding': binding, 'visibility': visibility, 'section': section}
    if rows != set(range(count)) or set(found) != set(required):
        raise ValueError('incomplete dynamic table or missing required ELF functions')
    return [found[name] for name in sorted(required)]


def required_private_elf_functions(text, required):
    """Require actual nonexported FUNC code in one complete .symtab.

    This is a private retention check, never a request to export a native helper.
    Candidate recipe must retain .symtab in packaged libmpv.so explicitly.
    """
    if not required or len(set(required)) != len(required):
        raise ValueError('invalid private ELF function contract')
    if not isinstance(text, str) or '\0' in text or len(text) > 32 * 1024**2:
        raise ValueError('invalid or oversized full symbol text')
    lines = text.splitlines()
    if len(lines) > 400000 or any(len(line) > 16384 for line in lines):
        raise ValueError('oversized full symbol table')
    headers = [(index, re.fullmatch(r"Symbol table '(\.dynsym|\.symtab)' contains ([0-9]+) entries:",
                                   line.strip()))
               for index, line in enumerate(lines) if line.strip().startswith('Symbol table ')]
    if (any(row is None for _, row in headers) or
            len({row.group(1) for _, row in headers}) != len(headers)):
        raise ValueError('malformed or duplicate full symbol-table header')
    starts = [index for index, row in headers if row.group(1) == '.symtab']
    if len(starts) != 1:
        raise ValueError('expected exactly one complete private .symtab table')
    start = starts[0]
    count = int(re.fullmatch(r"Symbol table '\.symtab' contains ([0-9]+) entries:",
                            lines[start].strip()).group(1))
    if not 1 <= count <= 400000:
        raise ValueError('invalid private symbol count')
    end = next((index for index in range(start + 1, len(lines))
                if lines[index].strip().startswith('Symbol table ')), len(lines))
    rows, found = set(), {}
    pattern = re.compile(r'\s*([0-9]+):\s+([0-9a-fA-F]+)\s+([0-9]+)\s+'
                         r'(\S+)\s+(\S+)\s+(\S+)\s+(\S+)(?:\s+(\S+))?\s*')
    for line in lines[start + 1:end]:
        if not re.match(r'\s*[0-9]+:', line):
            continue
        row = pattern.fullmatch(line)
        if not row or len(row.group(2)) > 16:
            raise ValueError('malformed private symbol row')
        index, value, size, kind, binding, visibility, section, raw = row.groups()
        index = int(index)
        if index >= count or index in rows:
            raise ValueError('duplicate or out-of-range private symbol index')
        rows.add(index)
        if raw not in required:
            continue
        if (raw in found or kind != 'FUNC' or int(size) <= 0 or
                not re.fullmatch(r'[0-9]+', section) or int(section) <= 0 or
                (binding, visibility) not in {('LOCAL', 'DEFAULT'), ('LOCAL', 'HIDDEN'),
                                               ('GLOBAL', 'HIDDEN')}):
            raise ValueError('private helper is missing unique nonexported code: ' + raw)
        found[raw] = {'name': raw, 'size': int(size), 'type': kind,
                      'binding': binding, 'visibility': visibility, 'section': section}
    if rows != set(range(count)) or set(found) != set(required):
        raise ValueError('incomplete private table or missing private code')
    return [found[name] for name in sorted(required)]


def reader_identity(reader, mode):
    requested = reader.absolute()
    resolved = requested.resolve(strict=True)
    if not resolved.is_file():
        raise ValueError('selected inspection reader is not a regular file')
    # Preserve argv[0]: llvm-readelf can be a symlink to llvm-readobj, whose
    # resolved basename would select another output format if invoked directly.
    version = run(str(requested), '--version').strip()
    if not version or '\0' in version or len(version) > 4096:
        raise ValueError('unexpected inspection reader version output')
    return {'mode': mode, 'requestedReader': str(requested), 'resolvedReader': str(resolved),
            'readerSHA256': digest(resolved), 'readerVersion': version,
            'validatorSHA256': digest(Path(__file__))}


def required_macho_functions(text, required, role, forbidden=()):
    """The caller selects real nm -gU definitions or -gu undefined externals."""
    if role not in ('defined-code', 'undefined-import') or not required or len(set(required)) != len(required):
        raise ValueError('invalid required Mach-O function contract')
    if not isinstance(text, str) or '\0' in text or len(text) > 32 * 1024**2:
        raise ValueError('invalid or oversized nm text')
    found = set()
    for line in text.splitlines():
        line = line.strip()
        if not line or line.endswith(':'):
            continue
        row = re.fullmatch(r'(?:[0-9a-fA-F]+\s+)?([A-Za-z?])\s+(\S+)', line)
        if not row:
            if any('_' + name in line for name in required):
                raise ValueError('malformed required nm row')
            continue
        kind, raw = row.groups()
        if raw.lstrip('_').split('@', 1)[0] in forbidden:
            raise ValueError('retired Mach-O bridge symbol')
        name = raw[1:] if raw.startswith('_') else raw
        if name not in required:
            if raw.lstrip('_').split('@', 1)[0] in required:
                raise ValueError('wrong required Mach-O symbol spelling')
            continue
        correct_type = kind in ('T', 't') if role == 'defined-code' else kind == 'U'
        if raw != '_' + name or name in found or not correct_type:
            raise ValueError('duplicate or wrong-type required Mach-O function: ' + name)
        found.add(name)
    if found != set(required):
        raise ValueError('missing required Mach-O functions')
    return sorted(found)


def apple_sent_abi(package, *, lipo=None, nm=None):
    slices = {'ios-arm64': {'arm64'}, 'ios-arm64_x86_64-simulator': {'arm64', 'x86_64'},
              'tvos-arm64_arm64e': {'arm64', 'arm64e'},
              'tvos-arm64_x86_64-simulator': {'arm64', 'x86_64'},
              'macos-arm64_x86_64': {'arm64', 'x86_64'}}
    if not package.is_dir():
        raise ValueError('expected a staged Apple package directory')
    package = package.resolve(strict=True)
    for tool in (lipo, nm):
        if tool is not None and not tool.is_absolute():
            raise ValueError('explicit Apple inspection tools must be absolute paths')
    lipo_command = (str(lipo),) if lipo is not None else ('xcrun', 'lipo')
    nm_command = (str(nm),) if nm is not None else ('xcrun', 'nm')
    with tempfile.TemporaryDirectory(prefix='.sent-request-abi-', dir=package.parent) as temporary:
        for library, functions in (('Libavformat', SENT_FFMPEG_FUNCTIONS + REFERENCE_FFMPEG_FUNCTIONS),
                                   ('Libmpv', SENT_MPV_FUNCTIONS)):
            xc = package / 'artifacts' / (library + '-GPL.xcframework')
            if not xc.is_dir():
                raise ValueError('missing sent-request XCFramework')
            if {p.name for p in xc.iterdir() if p.is_dir()} != set(slices):
                raise ValueError('wrong exact sent-request Apple slice set')
            for slice_name, expected in slices.items():
                framework = xc / slice_name / (library + '.framework')
                binary = framework / library
                if not framework.is_dir() or not binary.is_file():
                    raise ValueError('missing staged Apple archive')
                archs = run(*lipo_command, '-archs', str(binary)).split()
                if len(archs) != len(expected) or set(archs) != expected:
                    raise ValueError('wrong exact staged Apple architecture set')
                for arch in sorted(expected):
                    thin = Path(temporary) / (library + '-' + slice_name + '-' + arch + '.a')
                    if len(expected) == 1:
                        shutil.copyfile(binary, thin)
                    else:
                        run(*lipo_command, str(binary), '-thin', arch, '-output', str(thin))
                    required_macho_functions(run(*nm_command, '-gU', str(thin)), functions, 'defined-code',
                                             RETIRED_SENT_FFMPEG_FUNCTIONS)
                    if library == 'Libmpv':
                        required_macho_functions(run(*nm_command, '-gu', str(thin)),
                                                SENT_FFMPEG_FUNCTIONS + REFERENCE_FFMPEG_FUNCTIONS, 'undefined-import',
                                                RETIRED_SENT_FFMPEG_FUNCTIONS)
    print('PASS apple-sent-abi')
    print('PASS apple-reference-abi')


def android(out, upstream, sdk, *, readelf=None):
    explicit_reader = readelf is not None
    if explicit_reader and not readelf.is_absolute():
        raise ValueError('explicit inspection reader must be an absolute path')
    if readelf is None:
        readelf = sdk / 'ndk/30.0.16248370/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-readelf'
    readelf = readelf.absolute()
    reader = reader_identity(readelf, 'explicit-read-only-inspector' if explicit_reader else 'hosted-ndk-reader')
    inspection = reader if explicit_reader else None
    aar = out / 'libmpv-release-candidate.aar'
    machines = {'arm64-v8a': ('ELF64', 'AArch64'), 'armeabi-v7a': ('ELF32', 'ARM'),
                'x86_64': ('ELF64', 'Advanced Micro Devices X86-64')}
    required = {'libmpv.so', 'libplayer.so', 'libc++_shared.so', 'libavcodec.so', 'libavformat.so',
                'libavutil.so', 'libavfilter.so', 'libavdevice.so', 'libswresample.so', 'libswscale.so'}
    source_header = (out / 'tls_mbedtls_vortx_distrust.h').read_text()
    keys = [bytes(int(x, 16) for x in re.findall(r'0x([0-9a-f]{2})', line))
            for line in source_header.splitlines() if '}, /* EM' in line]
    if len(keys) != 8 or any(len(key) != 32 for key in keys):
        raise ValueError('unexpected reviewed distrust table')
    records, sent_records, private_records, reference_records = [], [], [], []
    with zipfile.ZipFile(aar) as archive, tempfile.TemporaryDirectory(dir=out) as temporary:
        names = archive.namelist()
        if len(names) != len(set(names)):
            raise ValueError('duplicate AAR entries')
        libraries = [name for name in names if name.startswith('jni/') and name.endswith('.so')]
        if {name.split('/')[1] for name in libraries} != set(machines):
            raise ValueError('AAR must contain exactly three admitted native ABIs')
        for abi, (elf_class, machine) in machines.items():
            present = {name.split('/')[-1] for name in libraries if name.startswith(f'jni/{abi}/')}
            if not required <= present:
                raise ValueError(f'missing packaged media library: {abi}: {sorted(required - present)}')
            for name in sorted(n for n in libraries if n.startswith(f'jni/{abi}/')):
                if len(name.split('/')) != 3 or archive.getinfo(name).file_size > 512 * 1024**2:
                    raise ValueError('unexpected native entry shape/size')
                data = archive.read(name)
                target = Path(temporary) / 'library.so'
                target.write_bytes(data)
                header = run(str(readelf), '-h', str(target))
                if (not re.search(r'Class:\s+' + elf_class + r'\b', header) or not re.search(
                        r'Machine:\s+' + re.escape(machine) + r'\s*$', header, re.M)
                        or not re.search(r'Type:\s+DYN\b', header) or 'little endian' not in header):
                    raise ValueError(f'wrong native ELF identity: {name}')
                segments = run(str(readelf), '-W', '-l', str(target)).splitlines()
                loads = [line.split() for line in segments if line.strip().startswith('LOAD ')]
                relro = [line.split() for line in segments if line.strip().startswith('GNU_RELRO ')]
                if not loads or (elf_class == 'ELF64' and (not relro or any(
                        int(row[-1], 16) < 16384 or (int(row[2], 16) - int(row[1], 16)) % 16384
                        for row in loads) or any(not relro_16k_safe(row, loads) for row in relro))):
                    raise ValueError(f'not 16 KiB compatible: {name}')
                if name.endswith('/libavformat.so'):
                    if any(flag not in data for flag in (b'--enable-mbedtls', b'--enable-gpl', b'--enable-version3')):
                        raise ValueError(f'expected TLS/GPL configuration missing: {name}')
                    if any(key not in data for key in keys):
                        raise ValueError(f'distrust-key constants missing: {name}')
                library = name.split('/')[-1]
                if library in ('libavformat.so', 'libmpv.so'):
                    role = 'defined-provider' if library == 'libavformat.so' else 'undefined-import'
                    dynamic = run(str(readelf), '--dyn-syms', '--wide', str(target))
                    symbols = required_elf_functions(dynamic, SENT_FFMPEG_FUNCTIONS, role,
                                                     RETIRED_SENT_FFMPEG_FUNCTIONS +
                                                     (PRIVATE_MPV_FUNCTIONS if library == 'libmpv.so' else ()))
                    sent_records.append({'abi': abi, 'library': library, 'role': role,
                                         'binarySHA256': hashlib.sha256(data).hexdigest(),
                                         'dynsymTextSHA256': hashlib.sha256(dynamic.encode('utf-8')).hexdigest(),
                                         'symbols': symbols})
                    reference = required_elf_functions(dynamic, REFERENCE_FFMPEG_FUNCTIONS, role)
                    reference_records.append({'abi': abi, 'library': library, 'role': role,
                                              'binarySHA256': hashlib.sha256(data).hexdigest(),
                                              'dynsymTextSHA256': hashlib.sha256(dynamic.encode('utf-8')).hexdigest(),
                                              'symbols': reference})
                    if library == 'libmpv.so':
                        full = run(str(readelf), '--symbols', '--wide', str(target))
                        private = required_private_elf_functions(full, PRIVATE_MPV_FUNCTIONS)
                        private_records.append({'abi': abi, 'library': library,
                                                'binarySHA256': hashlib.sha256(data).hexdigest(),
                                                'symtabTextSHA256': hashlib.sha256(full.encode('utf-8')).hexdigest(),
                                                'symbols': private})
                records.append({'entry': name, 'sha256': hashlib.sha256(data).hexdigest(),
                                'bytes': len(data), 'elfIdentityChecked': True,
                                'loadAlignments': [int(row[-1], 16) for row in loads],
                                'page16KiBChecked': elf_class == 'ELF64'})
    if (str(readelf.resolve(strict=True)) != reader['resolvedReader'] or
            digest(Path(reader['resolvedReader'])) != reader['readerSHA256']):
        raise ValueError('selected inspection reader changed during ABI inspection')
    evidence = {
        'aarSHA256': digest(aar), 'libraries': records, 'runtimeSecurityTested': False,
        'appAndSeamBindingChanged': False, 'promotionEligible': False,
        'sentRequestABI': {'schema': 2, 'reader': reader, 'libraries': sent_records,
                           'retiredV1Absent': True},
        'referenceReaderABI': {'schema': 1, 'reader': reader, 'libraries': reference_records},
        'privateOwnerABI': {'schema': 1, 'reader': reader, 'libraries': private_records}}
    if inspection is not None:
        # This describes only the inspection host/tool, never the original producer's NDK.
        evidence['inspection'] = inspection
    save(out / 'android-artifact-evidence.json', evidence)


# Exact source-evidence profile for FUTURE successful native candidates. This
# carries source bytes, including new/untracked patch outputs, rather than
# substituting tracked diffs for a complete corresponding-source snapshot.
CURRENT_SOURCE_PROFILE = 'original-http-sparse-native-reference-reader-v2-dependencies-openssl410-crypto-subtitles-bluray150-freetype2150-libdovi340-candidate'
CURRENT_RECIPE_PATHS = {
    'scripts/assemble-mpvkit-dvfel.sh', 'scripts/build-mpvkit-dvfel.sh',
    'scripts/ffmpeg-response-witness.patch', 'scripts/ffmpeg-response-generation.patch',
    'scripts/mpv-completed-response-observation.patch',
    'scripts/ffmpeg-sent-request-evidence.patch', 'scripts/mpv-sent-request-evidence.patch',
    'scripts/mpv-bounded-prefix-request.patch',
    'scripts/ffmpeg-original-transport-evidence.patch', 'scripts/mpv-original-transport-evidence.patch',
    'scripts/ffmpeg-finite-reference-reader.patch', 'scripts/mpv-finite-reference-reader.patch',
    'scripts/mpv-coreaudio-hotplug-lifecycle.patch', 'scripts/mpv-http-seek-interrupt.patch',
    'scripts/mpv-moltenvk-resize.patch', 'scripts/mpv-original-http-reference-recipe.patch',
    'scripts/mpv-original-http-cancel-lifetime.patch', 'scripts/mpv-original-local-file-witness.patch',
    'scripts/mpv-owned-subtitle-constructor.patch', 'scripts/mpv-owned-subtitle-publication.patch',
    'scripts/mpv-upstream-audio-layout-bounds.patch', 'scripts/mpv-upstream-edition-title-lifetime.patch',
    'scripts/mpv-upstream-gpu-next-seek-reset.patch', 'scripts/mpvkit-dvfel.patch',
    'scripts/native-media-hosted/android-assembly.patch',
    'scripts/native-media-hosted/android/buildscripts/include/depinfo.sh',
    'scripts/native-media-hosted/android/buildscripts/include/download-deps.sh',
    'scripts/native-media-hosted/android/buildscripts/include/download-lua.sh',
    'scripts/native-media-hosted/android/buildscripts/include/download-libunibreak.sh',
    'scripts/native-media-hosted/android/buildscripts/patch.sh',
    'scripts/native-media-hosted/android/buildscripts/patches/ffmpeg/0001-emudhra-spki-distrust.patch',
    'scripts/native-media-hosted/android/buildscripts/scripts/ffmpeg.sh',
    'scripts/native-media-hosted/build.sh', 'scripts/native-media-hosted/evidence.py',
    'scripts/verify-mpvkit-dvfel-apple-tls.sh', 'scripts/verify-mpvkit-dvfel-artifacts.sh',
}
CURRENT_NATIVE_PINS = {'mpv': '8c67647b50059406c5c0444903597281b81516cf',
                       'ffmpeg': '946fcce07b6dcd0331c8cc609192aeff5e1924f8',
                       'libplacebo': '275f7dea27924cdd34ab2e6c20e448b6bc4fab65'}
# Full-file postcomposition hashes retain cancellation plus owned observation.
CURRENT_CANCEL_FILES = {
    'misc/thread_tools.c': '151102f6fc8584e119317e3526502bbae492353b1c312ae4a8f3aecaee8bdab9',
    'misc/thread_tools.h': '62c7ea467ef911d9665cc4d7ffe28b2b09ea03f152326964056f62dab24acc7f',
    'stream/stream_lavf.c': '650bf7b94771e70a6b934b21e362bc77f66ceb1d23ee684d2b169c6e694544a5',
    'stream/reference_source.h': '1f606a977b55f18fdb9f9fc7f5e4549b5774bef10a06c33b06ab945531909b29',
                     'stream/vortx_http_request.h': 'd7730cc3492f6eaf6f6f1134fa50331c13e251fb1ddab8e577e1b912b8679dc9',
}
CURRENT_RESPONSE_FILES = {
    'libavformat/http.c': 'd1301474b4389256f9862565a399a8888366a68d2e3630338848289fe8a9c831',
    'libavformat/url.h': '14e3acc5a6715d48edb3dadb2f5248deaa38c36b30ff763e9be4b89edf2b1a0c',
    'libavformat/avio.c': '16bf38abc7a5b5586268c71723041df2b90b7b99a8fbaeb06c8b20926534fe7a',
    'libavformat/tcp.c': 'cc9c11534ff5017d5931bb06788f95f10e9809953e5ec1cc03114a3a877cdcce',
    'libavformat/tls.c': '0f07be92b62cefb53c6db5552951c658c756fac36ce22b03ccca8a044f1911f2',
    'libavformat/tls.h': '257c76932de48ed84bf849a44ca9ea6fe85adb93a26bb4f7112b19000084ff19',
    'libavformat/tls_securetransport.c': 'b04fb28df85f1ef3883b4927d0bfab4477f400128c122f794ff13b4b9c85bebc',
}
CURRENT_READER_FFMPEG_CREATED = {
    'libavformat/vortx_reference_reader.inc': 'a8c74f929942423550dba65f738fd4d2ad2d63d975665f64e6da1b00f5001645',
    'libavformat/vortx_reference_pin.h': 'e0ccea8466e28169d0882fd664081baa09d3a39626d5351a31804b6dc4bb4e94',
    'libavformat/vortx_reference_reader_stream.h': 'adaeb9d58c20ba3305bce4784205c20d6276ba67a758a9ec7207c850c7ba8d87',
    'libavformat/vortx_reference_sparse.h': 'fa5f8e163d9368b30db6a9c7f0c69ed36e91d6a23ca409b7ba468c7d2282751c',
    'libavformat/vortx_reference_sparse.inc': '0e3201c26657765a1e6e7a15fe9db1bcac5cf96a8cb7e9d691533e0f4bf3f15f',
}
CURRENT_READER_MPV_FILES = {
    'demux/demux.c': 'f5a4cd7bf4e29902ef965e43027755c19ded1423129a3fbe9808ad89e64c0e1c',
    'demux/demux.h': 'bee52b38477ce7c8efd9a50e778f720ea8c9eec577afab29998682c26ffe75e2',
    'demux/demux_lavf.c': 'd945ae1699d383c3d645d2ab963abb166fd0c19f10a4ab144505e7fbfb0408fb',
    'demux/reference_reader.c': '222ec8920d38971d386470d8172e45a89a52350eb352124ddf954be9409b792b',
    'demux/reference_reader.h': '59d669fb370bc12f01856031b8f9d908eb1d50a927d955ecb1fe0b4484c2407d',
    'demux/reference_reader_internal.h': 'ded5dc02785e98934a966de87df4337e4c6aed0275bce26da2017883917f4c8d',
    'demux/demux_mkv.c': '1b7cc4d40efa0620bd10669dc44a7d6b32d0236e2ae2be3510a3bac0829e39c2',
    'demux/reference_mkv.h': '38df7814efc3aa7434e5afe269406a989ab6a5fa22a200aa28149a3ab68e46d9',
    'demux/reference_mkv_reader.c': '3ac442e8ff489d11f4a5df6b86f8d964457753f66ce5f3eb530d7db3746b6f7c',
    'demux/reference_mkv_sparse.h': '4b013b6e794257a576bc01f6becb9d120cb878e0851b2e0bdd2225dcf7b18df2',
    'demux/reference_mkv_sparse_planner.c': 'e36c6a879138b26e125f647c9254b41674b22b338ab12838376fe8d38bdae056',
    'demux/reference_mkv_sparse_planner.h': 'c88597a42186ceb81f45f1f44b3734469cf06889ea3bf91e4853b861943e84fe',
    'demux/reference_mkv_sparse_worker.c': '5deae68bf3c680aa4898ca6c8e0c0e76aa4628bffa693d0ae2d6dd287d9a5e64',
    'stream/vortx_reference_sparse.h': 'fa5f8e163d9368b30db6a9c7f0c69ed36e91d6a23ca409b7ba468c7d2282751c',
    'stream/stream_lavf.c': CURRENT_CANCEL_FILES['stream/stream_lavf.c'],
    'stream/reference_source.h': CURRENT_CANCEL_FILES['stream/reference_source.h'],
    'stream/vortx_reference_reader_stream.h': 'adaeb9d58c20ba3305bce4784205c20d6276ba67a758a9ec7207c850c7ba8d87',
    'player/owned_subtitle.c': '014b93845488ef873a4d29c4c8dd4ada69d244626e7a7b38bac82809989c6b29',
    'player/owned_subtitle.h': '8d2f0ee5c972d1da69213cd80fbe249bcf3f19d9de8a2ef87e241d2f08f06284',
    'player/command.c': 'e7a19f392bb69e9d208382f157234ac3c908d22a0d4afee5f372ee8f9d33dade',
    'player/reference_owned.inc': '23ac96bfedefcab2234afa2a6f329a36fac6735effca6798b4043d777b060217',
    'sub/owned_text_slot.h': '63c498dd4bdc9fa9c6d128f1be8f37d7cdf377c853888342897f6639601662f6',
    'sub/osd.c': '9b57ccd08e5777e2bc644cbf8001df0301552edf5cf24e36185a54f4cd667195',
    'sub/dec_sub.c': '6e2137b90fe7f2915a528bdd83426448afbd099229f65342dbfd85d1ba1d347b',
    'sub/dec_sub.h': 'cb9b5af7c3f87a8dda584617c1f20a90a9331182d54a50c7e5fb8e64e74b384f',
}
# Both maintained source lanes retain SENT/PREFIX's seven Android-conditional
# roots; only the Apple source includes MPVKit's MoltenVK configuration block.
CURRENT_READER_MPV_MESON = {
    'apple': 'c2abd8f89a772717fdd4bcdbb4a2236d9fb28eca029acfe84bf12f7333df5a55',
    'android': '32c9a1321883f6a980652173061c9c01727ef83b7a0dfe6e8e3a22364b753d47',
}
CURRENT_MBEDTLS_FILES = {'apple': '77d72cb88fc662b984f051335b356abc3e76e97ce39302dde6961ecdbba7a332',
                         'android': '7099664b2c15a784db38a0db7956f718862201ef6c02d27779b2fc654b44aeac'}
CURRENT_SOURCE_ROOTS = {'android': {'_native-publisher': 'fcf6745703dc1265bca88f12fee8fc355ddf251e',
             'dav1d': '54706fc6bc0cdecab7e9593974a4039cc038fca7',
             'ffmpeg': '946fcce07b6dcd0331c8cc609192aeff5e1924f8',
             'fontconfig': '0f236723a3c26bd9745e32ba2b3ee21e5f809295',
             'freetype': '0a0221a1347e2f1e07c395263540026e9a0aa7c7',
             'fribidi': 'b93119f5fdc7ea47672cc304c1455ffa6dfe7536',
             'harfbuzz': '35f656a1a2bab548ea7f54a6dd3fba2b09680d14',
             'libass': '4a05d8127f525943ebf45fdc6497c9e665947f0d',
             'libplacebo': '275f7dea27924cdd34ab2e6c20e448b6bc4fab65',
             'libxml2': '96498992efa48d52b0e8b83058bd88dbdaf153c1',
             'mbedtls': '068ff080b369adfac81509f9b57b2afabaf82dc5',
             'mpv': '8c67647b50059406c5c0444903597281b81516cf'},
 'apple': {'FFmpeg-9.0.2-946fcce0': '946fcce07b6dcd0331c8cc609192aeff5e1924f8',
           '_native-mpvkit': '2103893078c5e339073b11737b86f7f22b9c4491',
           'libmpv-master-8c67647b': '8c67647b50059406c5c0444903597281b81516cf',
           'libplacebo-7.387.0-275f7dea': '275f7dea27924cdd34ab2e6c20e448b6bc4fab65',
           'lcms2-2.20rc1-13154341': '1315434113566bcf3eb46c2485fcc1c0a56ab806',
           'libdav1d-1.5.4-54706fc6': '54706fc6bc0cdecab7e9593974a4039cc038fca7',
           'openssl-4.1.0-2f4e3a5f': '2f4e3a5fec05394068cfa7379890ab552483a8a6'}}
CURRENT_UNTRACKED_FILES = {'android': {'_native-publisher': {'buildscripts/include/download-libunibreak.sh': '34ce1ee52187a287ff7da6e18efd7368e5671ac77cc7da5c5a8027a3c63a0418',
                                   'buildscripts/patches/ffmpeg/0006-finite-reference-reader.patch': 'a06f4b8b9eadc12eace93b1b340e0555116061188d0674f063698ea75d953abd',
                                   'buildscripts/patches/mpv/0014-finite-reference-reader.patch': '42c020f9f6550af5072a8eff1b5860249bb9df5f9418855cb4636cd15854f7f2',
                                   'buildscripts/patches/ffmpeg/0005-original-transport-evidence.patch': '480302686b9fff135cd0665e7af76d635fc21d83f54ee0096578ddd6bd6d83e5',
                                   'buildscripts/patches/mpv/0013-original-transport-evidence.patch': 'dad7f2d20ea14eb4661ef853978be78806e1b01fce67653e3ffec9b57d4a0e82',
                                   'buildscripts/include/download-lua.sh': 'bdfb58aa6fc85ec4dabd095bf11c760482fbbff86b94abbe835044ea49f06f93',
                                   'buildscripts/patches/ffmpeg/0004-sent-request-evidence.patch': '085b66cb5623ed8087481d3217b65da587b2970cd345a45896e7e87823dec9c9',
                                   'buildscripts/patches/mpv/0011-sent-request-evidence.patch': 'e3840084725be1f4948fb90c6fec87c35d55665f8310854713ebff496e1358bf',
                                   'buildscripts/patches/mpv/0012-bounded-prefix-request.patch': 'edcfdc7d9d8da7f8a44b19d326a809de844be968cc8061b80744229da801331e',
                                   'buildscripts/patches/ffmpeg/0003-response-generation.patch': 'ddfb68b5d7ed3779cfa69a75a28e9d4b17bd4f28529cccf26a005e790da03098',
                                   'buildscripts/patches/mpv/0010-completed-response-observation.patch': 'c038924be4c9b0ef187e1e9336d201b866dfa6f13457817c6e8c2d484e882e8e',
                                   'buildscripts/patches/ffmpeg/0002-response-witness.patch': '6a2bf6d0feff31280470ac46e9c56b2e0a4522513959784dcb04aaf196334b9b',
                                   'buildscripts/patches/ffmpeg/0001-emudhra-spki-distrust.patch': 'b36837784dc5b8e80e98c0f606fa7baf6e05031c91b5ab4e90b608a0a2d19714',
                                   'buildscripts/patches/mpv/0001-http-seek-interrupt.patch': '3687df5112f6cdcc22fed61dec6a5e16dcff89d54a7174edcefefbddd3054c92',
                                   'buildscripts/patches/mpv/0002-upstream-audio-layout-bounds.patch': 'db5d356912fb0f2b3d83378c05d4bc20c0d68a752148484a4545c31dbbe444c6',
                                   'buildscripts/patches/mpv/0003-upstream-gpu-next-seek-reset.patch': '5b41fd8e830caf37a17c23877742b19df74b76dd7d8d649feaed0dca11940f65',
                                   'buildscripts/patches/mpv/0004-original-local-file-witness.patch': 'a91a8ef61c513ad41ef9501d04e03017094aa581ed8aa31d2668129ea500e480',
                                   'buildscripts/patches/mpv/0005-upstream-edition-title-lifetime.patch': 'c2b8e1524a384e9a9de92ffc061991590a7220bd80b3f951e52073af9f39cb7a',
                                   'buildscripts/patches/mpv/0006-owned-subtitle-constructor.patch': '21140def002aa67849aa1e502d38e0da0c560b1dd0e90bcf04181fe57bad750f',
                                   'buildscripts/patches/mpv/0007-owned-subtitle-publication.patch': '54b29e4101e4cf7ef95d450462725beb8ac44c2733f7a444961f66b41df78341',
                                   'buildscripts/patches/mpv/0008-original-http-reference-recipe.patch': '7d4eaa5236fa8b1b7fb2bd1500ff71aac48fa79fca9e790dfab0dee6d3f0023e',
                                   'buildscripts/patches/mpv/0009-original-http-cancel-lifetime.patch': '778b58c05129e397ed2f90408718f6b3a3feca84492485657d89e784bbee5722'},
             'dav1d': {},
             'ffmpeg': {**CURRENT_READER_FFMPEG_CREATED,
                        'libavformat/vortx_http_request.h': 'd7730cc3492f6eaf6f6f1134fa50331c13e251fb1ddab8e577e1b912b8679dc9',
                        'libavformat/tls_mbedtls_vortx_distrust.h': '376bd507b67b3b912443bda657465204b808518ea353d161e23e47e9b64c0bf4'},
             'fontconfig': {},
             'freetype': {},
             'fribidi': {},
             'harfbuzz': {},
             'libass': {},
             'libplacebo': {},
             'libxml2': {},
             'mbedtls': {},
             'mpv': {'player/owned_subtitle.c': CURRENT_READER_MPV_FILES['player/owned_subtitle.c'],
                     'player/owned_subtitle.h': CURRENT_READER_MPV_FILES['player/owned_subtitle.h'],
                     'player/reference_owned.inc': CURRENT_READER_MPV_FILES['player/reference_owned.inc'],
                     'demux/reference_reader.c': CURRENT_READER_MPV_FILES['demux/reference_reader.c'],
                     'demux/reference_reader.h': CURRENT_READER_MPV_FILES['demux/reference_reader.h'],
                     'demux/reference_reader_internal.h': CURRENT_READER_MPV_FILES['demux/reference_reader_internal.h'],
                     'stream/vortx_reference_reader_stream.h': CURRENT_READER_MPV_FILES['stream/vortx_reference_reader_stream.h'],
                     'demux/reference_mkv.h': CURRENT_READER_MPV_FILES['demux/reference_mkv.h'],
                     'demux/reference_mkv_reader.c': CURRENT_READER_MPV_FILES['demux/reference_mkv_reader.c'],
                     'demux/reference_mkv_sparse.h': CURRENT_READER_MPV_FILES['demux/reference_mkv_sparse.h'],
                     'demux/reference_mkv_sparse_planner.c': CURRENT_READER_MPV_FILES['demux/reference_mkv_sparse_planner.c'],
                     'demux/reference_mkv_sparse_planner.h': CURRENT_READER_MPV_FILES['demux/reference_mkv_sparse_planner.h'],
                     'demux/reference_mkv_sparse_worker.c': CURRENT_READER_MPV_FILES['demux/reference_mkv_sparse_worker.c'],
                     'stream/vortx_reference_sparse.h': CURRENT_READER_MPV_FILES['stream/vortx_reference_sparse.h'],
                     'stream/reference_source.h': CURRENT_CANCEL_FILES['stream/reference_source.h'],
                     'stream/vortx_http_request.h': 'd7730cc3492f6eaf6f6f1134fa50331c13e251fb1ddab8e577e1b912b8679dc9',
                     'sub/owned_text_slot.h': CURRENT_READER_MPV_FILES['sub/owned_text_slot.h']}},
 'apple': {'FFmpeg-9.0.2-946fcce0': {**CURRENT_READER_FFMPEG_CREATED,
                                  'libavformat/vortx_http_request.h': 'd7730cc3492f6eaf6f6f1134fa50331c13e251fb1ddab8e577e1b912b8679dc9'},
           '_native-mpvkit': {**CRYPTO_INSTALLED_HELPERS, **SUBTITLE_INSTALLED_HELPERS,
                              'Sources/BuildScripts/patch/FFmpeg/0003-sent-request-evidence.patch': '085b66cb5623ed8087481d3217b65da587b2970cd345a45896e7e87823dec9c9',
                              'Sources/BuildScripts/patch/FFmpeg/0005-finite-reference-reader.patch': 'a06f4b8b9eadc12eace93b1b340e0555116061188d0674f063698ea75d953abd',
                              'Sources/BuildScripts/patch/libmpv/0019-finite-reference-reader.patch': '42c020f9f6550af5072a8eff1b5860249bb9df5f9418855cb4636cd15854f7f2',
                              'Sources/BuildScripts/patch/FFmpeg/0004-original-transport-evidence.patch': '480302686b9fff135cd0665e7af76d635fc21d83f54ee0096578ddd6bd6d83e5',
                              'Sources/BuildScripts/patch/libmpv/0018-original-transport-evidence.patch': 'dad7f2d20ea14eb4661ef853978be78806e1b01fce67653e3ffec9b57d4a0e82',
                              'Sources/BuildScripts/patch/libmpv/0016-sent-request-evidence.patch': 'e3840084725be1f4948fb90c6fec87c35d55665f8310854713ebff496e1358bf',
                              'Sources/BuildScripts/patch/libmpv/0017-bounded-prefix-request.patch': 'edcfdc7d9d8da7f8a44b19d326a809de844be968cc8061b80744229da801331e',
                              'Sources/BuildScripts/patch/FFmpeg/0002-response-generation.patch': 'ddfb68b5d7ed3779cfa69a75a28e9d4b17bd4f28529cccf26a005e790da03098',
                              'Sources/BuildScripts/patch/libmpv/0015-completed-response-observation.patch': 'c038924be4c9b0ef187e1e9336d201b866dfa6f13457817c6e8c2d484e882e8e',
                              'Sources/BuildScripts/patch/FFmpeg/0001-response-witness.patch': '6a2bf6d0feff31280470ac46e9c56b2e0a4522513959784dcb04aaf196334b9b',
                              'Sources/BuildScripts/patch/libmpv/0004-moltenvk-context-check-events-resize.patch': 'c88bd8e3db721953559138dbf3cc4814cff89e71527cf667ed7b6e8c1b3e1e7d',
                              'Sources/BuildScripts/patch/libmpv/0005-coreaudio-hotplug-lifecycle.patch': '01079c34bc8dba62af7e6f5a724063d288a96f2c4b5d2fb75b1993f6085a5ec5',
                              'Sources/BuildScripts/patch/libmpv/0006-http-seek-interrupt.patch': '3687df5112f6cdcc22fed61dec6a5e16dcff89d54a7174edcefefbddd3054c92',
                              'Sources/BuildScripts/patch/libmpv/0007-upstream-audio-layout-bounds.patch': 'db5d356912fb0f2b3d83378c05d4bc20c0d68a752148484a4545c31dbbe444c6',
                              'Sources/BuildScripts/patch/libmpv/0008-upstream-gpu-next-seek-reset.patch': '5b41fd8e830caf37a17c23877742b19df74b76dd7d8d649feaed0dca11940f65',
                              'Sources/BuildScripts/patch/libmpv/0009-original-local-file-witness.patch': 'a91a8ef61c513ad41ef9501d04e03017094aa581ed8aa31d2668129ea500e480',
                              'Sources/BuildScripts/patch/libmpv/0010-upstream-edition-title-lifetime.patch': 'c2b8e1524a384e9a9de92ffc061991590a7220bd80b3f951e52073af9f39cb7a',
                              'Sources/BuildScripts/patch/libmpv/0011-owned-subtitle-constructor.patch': '21140def002aa67849aa1e502d38e0da0c560b1dd0e90bcf04181fe57bad750f',
                              'Sources/BuildScripts/patch/libmpv/0012-owned-subtitle-publication.patch': '54b29e4101e4cf7ef95d450462725beb8ac44c2733f7a444961f66b41df78341',
                              'Sources/BuildScripts/patch/libmpv/0013-original-http-reference-recipe.patch': '7d4eaa5236fa8b1b7fb2bd1500ff71aac48fa79fca9e790dfab0dee6d3f0023e',
                              'Sources/BuildScripts/patch/libmpv/0014-original-http-cancel-lifetime.patch': '778b58c05129e397ed2f90408718f6b3a3feca84492485657d89e784bbee5722'},
           'libmpv-master-8c67647b': {'player/owned_subtitle.c': CURRENT_READER_MPV_FILES['player/owned_subtitle.c'],
                                      'player/owned_subtitle.h': CURRENT_READER_MPV_FILES['player/owned_subtitle.h'],
                                      'player/reference_owned.inc': CURRENT_READER_MPV_FILES['player/reference_owned.inc'],
                                      'demux/reference_reader.c': CURRENT_READER_MPV_FILES['demux/reference_reader.c'],
                                      'demux/reference_reader.h': CURRENT_READER_MPV_FILES['demux/reference_reader.h'],
                                      'demux/reference_reader_internal.h': CURRENT_READER_MPV_FILES['demux/reference_reader_internal.h'],
                                      'stream/vortx_reference_reader_stream.h': CURRENT_READER_MPV_FILES['stream/vortx_reference_reader_stream.h'],
                                      'demux/reference_mkv.h': CURRENT_READER_MPV_FILES['demux/reference_mkv.h'],
                                      'demux/reference_mkv_reader.c': CURRENT_READER_MPV_FILES['demux/reference_mkv_reader.c'],
                                      'demux/reference_mkv_sparse.h': CURRENT_READER_MPV_FILES['demux/reference_mkv_sparse.h'],
                                      'demux/reference_mkv_sparse_planner.c': CURRENT_READER_MPV_FILES['demux/reference_mkv_sparse_planner.c'],
                                      'demux/reference_mkv_sparse_planner.h': CURRENT_READER_MPV_FILES['demux/reference_mkv_sparse_planner.h'],
                                      'demux/reference_mkv_sparse_worker.c': CURRENT_READER_MPV_FILES['demux/reference_mkv_sparse_worker.c'],
                                      'stream/vortx_reference_sparse.h': CURRENT_READER_MPV_FILES['stream/vortx_reference_sparse.h'],
                                      'stream/reference_source.h': CURRENT_CANCEL_FILES['stream/reference_source.h'],
                     'stream/vortx_http_request.h': 'd7730cc3492f6eaf6f6f1134fa50331c13e251fb1ddab8e577e1b912b8679dc9',
                                      'sub/owned_text_slot.h': CURRENT_READER_MPV_FILES['sub/owned_text_slot.h'],
                                      'video/out/vulkan/context_moltenvk.m': '00d2842ddb0dca5070feaf890c0190a0fe62beef9b29ec36e94e329d29a3da5e'},
           'libplacebo-7.387.0-275f7dea': {},
           'lcms2-2.20rc1-13154341': {},
           'libdav1d-1.5.4-54706fc6': {},
           'openssl-4.1.0-2f4e3a5f': {}}}

CURRENT_SOURCE_ROOTS['apple'][DOVI_SOURCE_ROOT] = DOVI_SOURCE_COMMIT
CURRENT_UNTRACKED_FILES['apple'][DOVI_SOURCE_ROOT] = {}
CURRENT_UNTRACKED_FILES['apple']['_native-mpvkit'].update(DOVI_INSTALLED_HELPERS)
CURRENT_UNTRACKED_FILES['apple']['_native-mpvkit'].update(PLACEBO_INSTALLED_HELPERS)
CURRENT_RECIPE_PATHS.add('scripts/native-media-hosted/dovi-source-policy.json')
SOURCE_MAX_FILE = 64 * 1024**2
SOURCE_MAX_TOTAL = 2 * 1024**3
SOURCE_MAX_ENTRIES = 100000


def require_current_response_source(files, lane):
    # Source bytes only: no assertion about a live response, TLS, or a timing reader.
    if lane not in CURRENT_MBEDTLS_FILES:
        raise ValueError('unknown transport-evidence source lane')
    expected = dict(CURRENT_RESPONSE_FILES, **{
        'libavformat/tls_mbedtls.c': CURRENT_MBEDTLS_FILES[lane]})
    for name, checksum in expected.items():
        row = files.get(name, {})
        if row.get('kind') != 'file' or row.get('tracked') is not True or row.get('sha256') != checksum:
            raise ValueError('native source snapshot lacks exact response-witness afterimage: ' + name)
    for name, checksum in CURRENT_READER_FFMPEG_CREATED.items():
        row = files.get(name, {})
        if row.get('kind') != 'file' or row.get('tracked') is not False or row.get('sha256') != checksum:
            raise ValueError('native source snapshot lacks exact finite-reader private file: ' + name)


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


def _pp_original_blob(family, row):
    spec = PLAYER_PLAIN_SPECS[family]
    if digest(Path(LOCAL_SOURCE_GIT)) != LOCAL_SOURCE_GIT_SHA256:
        raise ValueError('plain source original Git reader changed')
    stores = {}
    for directory in {spec['objects'], spec['alternate'], spec['canonical'] + '/.git/objects'} - {None}:
        fd = source_root_fd(Path(directory)); os.close(fd)
        state = Path(directory).lstat(); stores[directory] = (state.st_dev, state.st_ino, state.st_mode)
        for suffix in ('info/alternates', 'info/http-alternates'):
            candidate = Path(directory) / suffix
            _pp_need(not candidate.exists() and not candidate.is_symlink(), 'undeclared original object-store alternate')
    env = {'PATH': '/usr/bin:/bin', 'LC_ALL': 'C', 'GIT_CONFIG_GLOBAL': '/dev/null', 'GIT_CONFIG_SYSTEM': '/dev/null',
           'GIT_CONFIG_NOSYSTEM': '1', 'GIT_OPTIONAL_LOCKS': '0', 'GIT_NO_REPLACE_OBJECTS': '1', 'GIT_NO_LAZY_FETCH': '1',
           'GIT_TERMINAL_PROMPT': '0', 'GIT_ASKPASS': '/usr/bin/false', 'GIT_OBJECT_DIRECTORY': spec['objects']}
    if spec['alternate'] is not None: env['GIT_ALTERNATE_OBJECT_DIRECTORIES'] = spec['alternate']
    command = [LOCAL_SOURCE_GIT, '--git-dir=' + spec['canonical'] + '/.git', '-c', 'core.hooksPath=/dev/null',
               '-c', 'core.fsmonitor=false', '-c', 'protocol.allow=never', 'cat-file', 'blob', row['gitBlobID']]
    run = subprocess.run(command, cwd=Path(PLAYER_PLAIN_WORK), env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
    _pp_need(run.returncode == 0 and run.stderr == b'' and len(run.stdout) <= 64 * 1024**2, 'strict original derivative object read')
    for directory, before in stores.items():
        state = Path(directory).lstat()
        _pp_need((state.st_dev, state.st_ino, state.st_mode) == before, 'original object-store identity conserved')
        for suffix in ('info/alternates', 'info/http-alternates'):
            candidate = Path(directory) / suffix
            _pp_need(not candidate.exists() and not candidate.is_symlink(), 'original object-store alternates remain absent')
    _pp_need(digest(Path(LOCAL_SOURCE_GIT)) == LOCAL_SOURCE_GIT_SHA256, 'original Git reader conserved')
    return run.stdout


def _pp_live(root, witness):
    proof, mapping, expected = _pp_witness(witness)
    fd = source_root_fd(root); os.close(fd)
    _pp_need(not (root / '.git').exists() and not (root / '.git').is_symlink(), 'plain player source must not contain Git metadata')
    actual = set()
    for current, dirs, files in os.walk(root, followlinks=False):
        for leaf in dirs + files:
            path = Path(current) / leaf; name = path.relative_to(root).as_posix(); actual.add(name)
            pin = proof['materializedTree'].get(name); _pp_need(pin is not None, 'undeclared plain-source entry')
            s = path.lstat()
            if pin['kind'] == 'directory':
                _pp_need(stat.S_ISDIR(s.st_mode) and stat.S_IMODE(s.st_mode) == pin['mode'], 'physical source directory/mode')
            elif pin['kind'] == 'symlink':
                _pp_need(stat.S_ISLNK(s.st_mode) and stat.S_IMODE(s.st_mode) == pin['mode'], 'source symlink type/mode')
                body = os.readlink(path).encode(); _pp_need(os.readlink(path) == pin['target'], 'source link target')
                _pp_body(body, mapping[name], witness, name)
            else:
                body, mode = _local_source_read(path, SOURCE_MAX_FILE)
                _pp_need(mode == pin['mode'], 'source file mode'); _pp_body(body, mapping[name], witness, name)
    _pp_need(actual == set(proof['materializedTree']), 'all physical source bodies and directories, no extras')
    return expected


def _pp_provider_snapshot(lane, upstream):
    if lane != 'apple' or upstream != Path(PLAYER_PLAIN_WORK): return {}
    selected = {}
    for family, spec in PLAYER_PLAIN_SPECS.items():
        root = upstream / 'dist' / spec['directory']
        if root.is_dir() and not (root / '.git').exists() and not (root / '.git').is_symlink(): selected[family] = root
    if not selected: return {}
    _pp_need(set(selected) == set(PLAYER_PLAIN_SPECS), 'both complete selected player source views are required')
    driver, _ = _local_source_read(upstream / 'Sources/BuildScripts/XCFrameworkBuild/main.swift', 2 * 1024**2)
    _pp_need(_pp_sha(driver) == PLAYER_PLAIN_DRIVER_SHA256, 'exact maintained player driver')
    materializer, _ = _local_source_read(Path(PLAYER_PLAIN_PREPARATION) / 'materialize.py', 1024**2)
    freeze, _ = _local_source_read(Path(PLAYER_PLAIN_PREPARATION) / 'FROZEN.json', 1024**2)
    _pp_need(_pp_sha(materializer) == PLAYER_PLAIN_MATERIALIZER_SHA256 and _pp_sha(freeze) == PLAYER_PLAIN_FREEZE_SHA256, 'exact corrected materializer controls')
    admission, _ = _local_source_read(upstream / 'dist/player-source-inputs/source-provider-admission.json', 1024**2)
    result = {}
    for family, root in selected.items():
        proof_body, _ = _local_source_read(Path(PLAYER_PLAIN_PREPARATION) / 'RUNTIME' / family / 'source-proof.json', 16 * 1024**2)
        proof, mapping, _ = _pp_proof(proof_body, family)
        compositions = []
        for path, expected_sha in PLAYER_PLAIN_COMPOSITIONS[family]:
            body, _ = _local_source_read(Path(path), 2 * 1024**2)
            _pp_need(_pp_sha(body) == expected_sha, 'unchanged accepted full-source composition proof'); compositions.append(body.decode())
        originals = {name: base64.b64encode(_pp_original_blob(family, row)).decode('ascii')
                     for name, row in mapping.items() if row['derivative']}
        witness = {'schema': 1, 'profile': PLAYER_PLAIN_PROFILE, 'family': family,
                   'currentBuildDriverSHA256': PLAYER_PLAIN_DRIVER_SHA256,
                   'materializerSHA256': PLAYER_PLAIN_MATERIALIZER_SHA256, 'materializerFreezeSHA256': PLAYER_PLAIN_FREEZE_SHA256,
                   'proofUTF8': proof_body.decode(), 'proofSHA256': _pp_sha(proof_body),
                   'admissionUTF8': admission.decode(), 'admissionSHA256': _pp_sha(admission), 'originalDerivativesBase64': originals, 'compositionUTF8': compositions}
        _pp_live(root, witness); result[str(root)] = witness
    return result


def _pp_source_paths(root, witness, allowed):
    _, mapping, _ = _pp_witness(witness); _pp_live(root, witness)
    _pp_need(set(allowed) <= set(mapping), 'all exact recipe-created sources exist')
    return sorted(mapping), [], sorted(set(mapping) - set(allowed)), [
        ('', PLAYER_PLAIN_SPECS[witness['family']]['base'], PLAYER_PLAIN_SPECS[witness['family']]['tree'], witness['proofSHA256'])]


def source_name(name):
    if (not isinstance(name, str) or not name or len(name.encode('utf-8')) > 4096
            or name.startswith('/') or '\\' in name or ':' in name
            or not name.isprintable()
            or any(p in ('', '.', '..') or p.casefold() == '.git' for p in name.split('/'))):
        raise ValueError('unsafe source evidence path')
    return name


def source_git(root, *args):
    if Path(root) in {Path(row['worktree']) for row in LOCAL_PROVIDER_ROLES.values()} | {Path(row['worktree']) for row in LP_ROLES.values()}:
        return _local_source_git(root,*args)
    env = {k: v for k, v in os.environ.items() if not k.startswith('GIT_')}
    env.update(GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_SYSTEM=os.devnull,
               GIT_CONFIG_NOSYSTEM='1', GIT_NO_REPLACE_OBJECTS='1', GIT_NO_LAZY_FETCH='1', LC_ALL='C')
    return subprocess.check_output(['git', '-c', 'core.hooksPath=/dev/null', '-c', 'core.fsmonitor=false',
                                    '-C', str(root), *args], env=env, timeout=60)


def _openssl_gitlink_placeholder(child):
    """Admit only an absent or empty real directory for a no-fetch submodule."""
    if child.is_symlink():
        raise ValueError('OpenSSL gitlink checkout must not be a symlink')
    if not child.exists():
        return
    if (not child.is_dir() or child.resolve() != child.absolute()
            or any(True for _ in child.iterdir())):
        raise ValueError('OpenSSL gitlink checkout must be absent or empty')


def source_paths(root, allowed_untracked):
    """Only pinned public Git roots and exact recipe-created untracked paths."""
    if root == Path(LP_ROLES['parent']['worktree']):
        return _lp_source_paths(root, allowed_untracked)
    paths, tracked, gitlinks, seen, identities = [], set(), [], set(), []
    openssl_root = (root.name == OPENSSL_ROOT and
                    source_git(root, 'rev-parse', 'HEAD').decode().strip() == OPENSSL_SOURCE['commit'])
    def visit(tree, prefix=''):
        if tree.is_symlink() or tree.resolve() != tree.absolute():
            raise ValueError('linked source checkout')
        if source_git(tree, 'diff', '--cached', '--name-only').strip():
            raise ValueError('staged native changes are not an admitted source snapshot')
        identities.append((prefix, source_git(tree, 'rev-parse', 'HEAD').decode().strip(),
                           hashlib.sha256(source_git(tree, 'ls-files', '--stage', '-z')).hexdigest(),
                           hashlib.sha256(source_git(tree, 'diff', '--no-ext-diff', '--no-textconv', '--binary')).hexdigest()))
        for entry in filter(None, source_git(tree, 'ls-files', '--stage', '-z').decode().split('\0')):
            identity, name = entry.split('\t', 1)
            mode, oid, stage = identity.split()
            relative = source_name(prefix + source_name(name))
            if stage != '0' or mode not in ('100644', '100755', '120000', '160000'):
                raise ValueError('unsupported source Git index entry')
            if mode == '160000':
                child = tree / name
                if openssl_root:
                    if relative not in OPENSSL_GITLINKS or OPENSSL_GITLINKS[relative] != oid:
                        raise ValueError('OpenSSL source Gitlink differs from the pinned root tree')
                    _openssl_gitlink_placeholder(child)
                    gitlinks.append({'path': relative, 'commit': oid})
                else:
                    if source_git(child, 'rev-parse', 'HEAD').decode().strip() != oid:
                        raise ValueError('native gitlink checkout differs from its pin')
                    gitlinks.append({'path': relative, 'commit': oid})
                    visit(child, relative + '/')
            else:
                paths.append(relative)
                tracked.add(relative)
        for name in filter(None, source_git(tree, 'ls-files', '--others', '--exclude-standard', '-z').decode().split('\0')):
            relative = source_name(prefix + source_name(name))
            if relative not in allowed_untracked:
                raise ValueError('unapproved untracked native source path')
            paths.append(relative)
    visit(root)
    if set(paths) - tracked != set(allowed_untracked):
        raise ValueError('recipe-created native source set is incomplete')
    if openssl_root and {row['path']: row['commit'] for row in gitlinks} != OPENSSL_GITLINKS:
        raise ValueError('OpenSSL source Gitlink set is incomplete or has extras')
    for name in paths:
        if name.casefold() in seen:
            raise ValueError('duplicate/case-colliding source path')
        seen.add(name.casefold())
    return sorted(paths), sorted(gitlinks, key=lambda row: row['path']), sorted(tracked), sorted(identities)


# The local producer uses only these two explicit registered providers. This
# does not select paths from the environment or change the default CI recipe.
LOCAL_PROVIDER_ROLES = {'wrapper': {'logical': '_native-mpvkit', 'canonical': '/Users/daksh/VortXTV/MPVKit', 'worktree': '/Users/daksh/VortXTV/.worktrees/MPVKit/beta-native-upgrades-20261027', 'origin': 'https://github.com/mpvkit/MPVKit.git', 'branch': 'beta/native-upgrades-20261027', 'commit': '2103893078c5e339073b11737b86f7f22b9c4491'}, 'dovi': {'logical': 'libdovi-3.4.0-d1abe0e2', 'canonical': '/Users/daksh/VortXTV/dovi-tool', 'worktree': '/Users/daksh/VortXTV/.worktrees/dovi-tool/beta/libdovi-3.4.0-d1abe0e2', 'origin': 'https://github.com/quietvoid/dovi_tool', 'branch': 'beta/libdovi-3.4.0-d1abe0e2', 'commit': 'd1abe0e27ff2c7ab3339614d06db9f8a058af6b2'}}
LOCAL_GIT_PROOF_PATH = '/Users/daksh/VortXTV/_recovery/resume-20261029/native-source-git-v1/RESULT.json'
LOCAL_GIT_PROOF_SHA256 = '1ec165439610a08624f433d90fad1c5834167a0cd6d9680ce9c742eb297f39fb'
LOCAL_BUILD_VIEW_PROOF_PATH = '/Users/daksh/VortXTV/_recovery/resume-20261029/native-source-git-v1/ROOT-PLAIN-BUILD-VIEW.json'
LOCAL_BUILD_VIEW_PROOF_SHA256 = 'd683236e1fa02c845e89dc4aca8a992ea7da7b9e27551ca391b63ee63d9fc4bf'
LOCAL_PROVIDER_REGISTRY = '/Users/daksh/VortXTV/.worktrees/REGISTRY.tsv'
LOCAL_SOURCE_GIT = '/Applications/Xcode.app/Contents/Developer/usr/bin/git'
LOCAL_SOURCE_GIT_SHA256 = '9a1c8fc68dc75e1b3c0cd8e5ad9d13ac9bc92cb53c9578b3cff4beaf2e9b1e70'


def _local_source_git(root, *args):
    env = {key: value for key, value in os.environ.items() if not key.startswith('GIT_')}
    env.update(GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_SYSTEM=os.devnull, GIT_CONFIG_NOSYSTEM='1',
               GIT_NO_REPLACE_OBJECTS='1', GIT_NO_LAZY_FETCH='1', GIT_OPTIONAL_LOCKS='0',
               GIT_TERMINAL_PROMPT='0', GIT_ASKPASS='/usr/bin/false', LC_ALL='C')
    return subprocess.check_output([LOCAL_SOURCE_GIT, '-c', 'core.hooksPath=/dev/null',
                                   '-c', 'core.fsmonitor=false', '-c', 'protocol.allow=never',
                                   '-C', str(root), *args], env=env, timeout=60)


def _local_provider_receipt_shape(value):
    expected = {'schema','scope','rootReviewedGenuineGitProof','rootReviewedPlainBuildView',
                'gitProofSHA256','plainBuildViewProofSHA256','sourceMapSHA256','bodyMapSHA256','wrapper','dovi'}
    if (type(value) is not dict or set(value) != expected or type(value['schema']) is not int
            or value['schema'] != 1 or value['scope'] != 'root-local-dovi-git-provider-v1'
            or value['rootReviewedGenuineGitProof'] is not True or value['rootReviewedPlainBuildView'] is not True
            or value['gitProofSHA256'] != LOCAL_GIT_PROOF_SHA256
            or value['plainBuildViewProofSHA256'] != LOCAL_BUILD_VIEW_PROOF_SHA256
            or value['sourceMapSHA256'] != DOVI_MAP_SHA
            or type(value['bodyMapSHA256']) is not str or not re.fullmatch('[0-9a-f]{64}',value['bodyMapSHA256'])):
        raise ValueError('explicit Root-reviewed exact local source-provider receipt required')
    for role in ('wrapper','dovi'):
        row = value[role]
        fields = {'indexSHA256','trackedDiffSHA256','registryRowSHA256'} | ({'tree'} if role == 'wrapper' else set())
        if type(row) is not dict or set(row) != fields:
            raise ValueError('local source-provider role shape differs')
        for name, body in row.items():
            if type(body) is not str or not re.fullmatch('[0-9a-f]{40}' if name == 'tree' else '[0-9a-f]{64}',body):
                raise ValueError('local source-provider identity encoding differs')
    if value['dovi']['trackedDiffSHA256'] != hashlib.sha256(b'').hexdigest():
        raise ValueError('Dovi provider must have a clean tracked source tree')
    return value


def _local_inline_receipt(inputs, receipt, expected_sha):
    if (type(inputs) is not dict or not dv_equal(inputs.get('localSourceProviderReceipt'),receipt)
            or type(inputs.get('localSourceProviderReceiptSHA256')) is not str
            or inputs['localSourceProviderReceiptSHA256'] != expected_sha):
        raise ValueError('retained inline Root source-provider witness differs in value or type')


def _local_no_alternates(body):
    if type(body) is not bytes or body:
        raise ValueError('local canonical Git objects must not borrow another object store')


def _local_registry_row(body, role, expected_sha):
    if (type(body) is not bytes or role not in ('wrapper','dovi') or type(expected_sha) is not str
            or not re.fullmatch('[0-9a-f]{64}',expected_sha)):
        raise ValueError('local registry observation shape differs')
    expected = LOCAL_PROVIDER_ROLES[role]
    selected = []
    for line in body.decode('utf-8','strict').splitlines():
        if not line or line.startswith('#'):
            continue
        fields = line.split(chr(9))
        if len(fields) >= 4 and fields[3] == expected['worktree']:
            selected.append((line,fields))
    if not selected:
        raise ValueError('local source worktree has no registry row')
    line,fields = selected[-1]
    if (len(fields) != 8 or fields[:4] != [expected['origin'],expected['canonical'],expected['branch'],expected['worktree']]
            or fields[6] != 'active' or hashlib.sha256(line.encode()).hexdigest() != expected_sha):
        raise ValueError('latest exact local source registry row differs or is inactive')
    return line


def _local_worktree_entry(body, role):
    if type(body) is not bytes or role not in ('wrapper','dovi'):
        raise ValueError('local worktree observation shape differs')
    expected = LOCAL_PROVIDER_ROLES[role]
    matches = []
    for block in body.decode('utf-8','strict').strip().split(chr(10)+chr(10)):
        fields = {}
        for line in block.splitlines():
            key,_,value = line.partition(' ')
            if key in fields:
                raise ValueError('duplicate Git worktree metadata field')
            fields[key] = value
        if fields.get('worktree') == expected['worktree']:
            matches.append(fields)
    if (len(matches) != 1 or set(matches[0]) != {'worktree','HEAD','branch'}
            or matches[0]['HEAD'] != expected['commit']
            or matches[0]['branch'] != 'refs/heads/'+expected['branch']):
        raise ValueError('actual Git worktree registration/branch/HEAD differs')
    return matches[0]


def _local_dovi_index(raw, mapping, tree=False):
    if type(tree) is not bool or type(raw) is not bytes or type(mapping) is not dict:
        raise ValueError('local Dovi index input shape differs')
    blobs = mapping.get('blobs')
    if type(blobs) is not list or len(blobs) != 209:
        raise ValueError('local Dovi source map must contain exactly209 blobs')
    expected = {}
    for item in blobs:
        name = source_name(item['path'])
        if (item['mode'] != '100644' or type(item['sha']) is not str or not re.fullmatch('[0-9a-f]{40}',item['sha'])
                or type(item.get('size')) is not int or not 0 <= item['size'] <= 64*1024**2 or name in expected):
            raise ValueError('local Dovi source map identity differs')
        expected[name] = item['sha']
    entries = raw.split(bytes([0]))
    if len(entries) != 210 or entries[-1] or not all(entries[:-1]):
        raise ValueError('local Dovi index/tree NUL framing differs')
    result = {}
    folded = set()
    for entry in entries[:-1]:
        identity,name = entry.decode('utf-8','strict').split(chr(9),1)
        parts = identity.split(' ')
        if len(parts) != 3:
            raise ValueError('local Dovi index record differs')
        mode, middle, last = parts
        oid = last if tree else middle
        if mode != '100644' or (middle != 'blob' if tree else last != '0') or not re.fullmatch('[0-9a-f]{40}',oid):
            raise ValueError('local Dovi index/tree modes, stages or object kind differ')
        name = source_name(name)
        if name in result or name.casefold() in folded or expected.get(name) != oid:
            raise ValueError('local Dovi index/tree file set or Git blob identity differs')
        result[name] = oid
        folded.add(name.casefold())
    if len(result) != 209 or result != expected:
        raise ValueError('local Dovi index/tree must equal all209 official blobs')
    return tuple(sorted(result))


def _source_logical_name(path, upstream, local):
    if local is not None:
        if upstream != Path(LOCAL_PROVIDER_ROLES['wrapper']['worktree']):
            raise ValueError('local source alias cannot select another wrapper')
        if path == upstream:
            return LOCAL_PROVIDER_ROLES['wrapper']['logical']
    return path.name


def _source_expected_root(lane, upstream, logical, index, local):
    source_name(logical)
    if type(index) is not int or index < 0:
        raise ValueError('native source receipt index differs')
    if local is not None and (lane != 'apple' or upstream != Path(LOCAL_PROVIDER_ROLES['wrapper']['worktree'])):
        raise ValueError('local source provider cannot select another lane or wrapper')
    if index == 0:
        return upstream
    if local is not None and logical == DOVI_SOURCE_ROOT:
        return Path(LOCAL_PROVIDER_ROLES['dovi']['worktree'])
    if local is not None and logical == LP_SOURCE_ROOT:
        return Path(LP_ROLES['parent']['worktree'])
    return upstream / ('dist' if lane == 'apple' else 'buildscripts/deps') / logical


def _local_source_read(path, maximum):
    if path != path.absolute():
        raise ValueError('local source input path must be absolute')
    parent = source_root_fd(path.parent)
    try:
        before = os.stat(path.name,dir_fd=parent,follow_symlinks=False)
        fd = os.open(path.name,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK,dir_fd=parent)
        with os.fdopen(fd,'rb') as stream:
            opened = os.fstat(stream.fileno())
            def identity(info):
                return info.st_dev,info.st_ino,info.st_mode,info.st_nlink,info.st_size,info.st_mtime_ns,info.st_ctime_ns
            if (not stat.S_ISREG(opened.st_mode) or opened.st_nlink != 1
                    or not 0 <= opened.st_size <= maximum or identity(before) != identity(opened)):
                raise ValueError('unsafe or replaced local source input')
            body = stream.read(maximum+1)
            after = os.fstat(stream.fileno())
        final = os.stat(path.name,dir_fd=parent,follow_symlinks=False)
        if len(body) != opened.st_size or identity(opened) != identity(after) or identity(after) != identity(final):
            raise ValueError('local source input changed while reading')
        return body,stat.S_IMODE(opened.st_mode)
    finally:
        os.close(parent)


def _local_git_identity(role, expected):
    spec = LOCAL_PROVIDER_ROLES[role]
    root,canonical = Path(spec['worktree']),Path(spec['canonical'])
    for directory in (root,canonical,canonical/'.git'):
        fd = source_root_fd(directory)
        os.close(fd)
    objects = canonical/'.git/objects'
    fd = source_root_fd(objects)
    os.close(fd)
    for name in ('alternates','http-alternates'):
        path = objects/'info'/name
        if path.exists() or path.is_symlink():
            body,_ = _local_source_read(path,64*1024)
            _local_no_alternates(body)
    if _local_source_git(root,'rev-parse','--show-toplevel').decode().strip() != str(root):
        raise ValueError('local provider is not its own genuine Git toplevel')
    common = Path(_local_source_git(root,'rev-parse','--git-common-dir').decode().strip())
    common = common if common.is_absolute() else root/common
    if common.resolve() != canonical/'.git':
        raise ValueError('local provider common Git directory differs')
    admin = Path(_local_source_git(root,'rev-parse','--absolute-git-dir').decode().strip())
    if admin.parent != canonical/'.git/worktrees' or admin.resolve() != admin:
        raise ValueError('local provider lacks its canonical worktree administration directory')
    marker,_ = _local_source_read(root/'.git',4096)
    backlink,_ = _local_source_read(admin/'gitdir',4096)
    if (marker.decode().strip() != 'gitdir: '+str(admin)
            or backlink.decode().strip() != str(root/'.git')):
        raise ValueError('local source worktree metadata back-links differ')
    if (_local_source_git(canonical,'remote').decode().splitlines() != ['origin']
            or _local_source_git(canonical,'config','--get-all','remote.origin.url').decode().splitlines() != [spec['origin']]):
        raise ValueError('local canonical source origin differs or is ambiguous')
    _local_worktree_entry(_local_source_git(canonical,'worktree','list','--porcelain'),role)
    if (_local_source_git(root,'symbolic-ref','-q','HEAD').decode().strip() != 'refs/heads/'+spec['branch']
            or _local_source_git(root,'rev-parse','HEAD').decode().strip() != spec['commit']):
        raise ValueError('local provider branch or full HEAD differs')
    commit = _local_source_git(root,'cat-file','commit',spec['commit'])
    if hashlib.sha1(b'commit '+str(len(commit)).encode()+bytes([0])+commit).hexdigest() != spec['commit']:
        raise ValueError('local provider raw commit object identity differs')
    tree = _local_source_git(root,'rev-parse','HEAD^{tree}').decode().strip()
    wanted_tree = 'b2183f7cc3d62918ad43b346835a2dab7d2ad875' if role == 'dovi' else expected['tree']
    tree_body = _local_source_git(root,'cat-file','tree',tree)
    if tree != wanted_tree or hashlib.sha1(b'tree '+str(len(tree_body)).encode()+bytes([0])+tree_body).hexdigest() != tree:
        raise ValueError('local provider actual tree object identity differs')
    index = _local_source_git(root,'ls-files','--stage','-z')
    diff = _local_source_git(root,'diff','--no-ext-diff','--no-textconv','--binary')
    if (_local_source_git(root,'diff','--cached','--name-only').strip()
            or hashlib.sha256(index).hexdigest() != expected['indexSHA256']
            or hashlib.sha256(diff).hexdigest() != expected['trackedDiffSHA256']):
        raise ValueError('local provider index/staged/tracked state differs from Root receipt')
    return {'tree':tree,'index':index,'diffSHA256':hashlib.sha256(diff).hexdigest()}


def _local_dovi_bodies(root, mapping, git_provider):
    fd = source_root_fd(root)
    os.close(fd)
    if not git_provider and ((root/'.git').exists() or (root/'.git').is_symlink()):
        raise ValueError('plain Dovi build view must not contain Git metadata')
    expected = {item['path']:item for item in mapping['blobs']}
    directories = {str(parent) for name in expected for parent in Path(name).parents if str(parent) != '.'}
    actual = set()
    for current,dirs,files in os.walk(root,followlinks=False):
        relative = Path(current).relative_to(root)
        for name in dirs:
            child = Path(current)/name
            if child.is_symlink() or child.relative_to(root).as_posix() not in directories:
                raise ValueError('extra or linked local Dovi source directory')
        for name in files:
            path = Path(current)/name
            if relative == Path('.') and name == '.git' and git_provider:
                continue
            actual.add(path.relative_to(root).as_posix())
    if actual != set(expected):
        raise ValueError('local Dovi source must contain exactly209 official files')
    result,total = [],0
    for name in sorted(expected):
        pin = expected[name]
        body,mode = _local_source_read(root/name,64*1024**2)
        oid = hashlib.sha1(b'blob '+str(len(body)).encode()+bytes([0])+body).hexdigest()
        total += len(body)
        if mode != 0o644 or len(body) != pin['size'] or oid != pin['sha'] or total > 64*1024**2:
            raise ValueError('local Dovi body/mode differs from its exact official Git blob')
        result.append({'path':name,'bytes':len(body),'gitBlobSHA1':oid,'mode':'100644','sha256':hashlib.sha256(body).hexdigest()})
    return result


def _local_provider_mode(lane, upstream):
    if lane != 'apple':
        return False
    if upstream == Path(LOCAL_PROVIDER_ROLES['wrapper']['worktree']):
        return True
    if upstream.is_relative_to(Path('/Users/daksh/VortXTV')):
        raise ValueError('local Apple source capture requires its fixed registered wrapper')
    return False


def _local_provider_snapshot(lane, upstream):
    if not _local_provider_mode(lane,upstream):
        return None
    git_body,_ = _local_source_read(Path(LOCAL_SOURCE_GIT),8*1024**2)
    if hashlib.sha256(git_body).hexdigest() != LOCAL_SOURCE_GIT_SHA256:
        raise ValueError('local source Git provider changed')
    root = upstream/'dist/dovi-inputs'
    receipt_body,_ = _local_source_read(root/'source-provider-admission.json',1024**2)
    receipt = _local_provider_receipt_shape(dv_json(receipt_body))
    inputs_body,_ = _local_source_read(root/'inputs.json',64*1024**2)
    inputs = dv_json(inputs_body)
    admission_body,_ = _local_source_read(root/'admission.json',1024**2)
    admission = dv_json(admission_body)
    payload = {key:value for key,value in inputs.items() if key not in ('admissionReceiptPath','admissionReceiptSHA256')}
    _local_inline_receipt(inputs,receipt,hashlib.sha256(receipt_body).hexdigest())
    if (inputs.get('profile') != DOVI_SOURCE_PROFILE
            or inputs.get('admissionReceiptPath') != str(root/'admission.json')
            or inputs.get('admissionReceiptSHA256') != hashlib.sha256(admission_body).hexdigest()
            or admission.get('profile') != DOVI_SOURCE_PROFILE or admission.get('sourceInputsAccepted') is not True
            or admission.get('inputsPayloadSHA256') != hashlib.sha256(json.dumps(payload,sort_keys=True,separators=(',',':')).encode()).hexdigest()):
        raise ValueError('Root provider receipt is not bound to the final admitted Dovi inputs')
    proof_body,_ = _local_source_read(Path(LOCAL_GIT_PROOF_PATH),1024**2)
    if hashlib.sha256(proof_body).hexdigest() != LOCAL_GIT_PROOF_SHA256:
        raise ValueError('actual Root genuine Git proof changed')
    proof = dv_json(proof_body)
    if (proof.get('head') != DOVI_SOURCE_COMMIT or proof.get('tree') != 'b2183f7cc3d62918ad43b346835a2dab7d2ad875'
            or proof.get('canonicalRepository') != LOCAL_PROVIDER_ROLES['dovi']['canonical']
            or proof.get('registeredWorktree') != LOCAL_PROVIDER_ROLES['dovi']['worktree']
            or proof.get('officialRemote') != LOCAL_PROVIDER_ROLES['dovi']['origin']
            or proof.get('branch') != LOCAL_PROVIDER_ROLES['dovi']['branch']
            or proof.get('indexEntries') != 209 or proof.get('gitlinks') != 0
            or proof.get('worktreeClean') is not True or proof.get('registryWrittenAndReadBack') is not True
            or proof.get('matchesAuthenticatedPreparedExport') is not True):
        raise ValueError('actual Root proof is not the fixed genuine Dovi provider')
    view_proof_body,_ = _local_source_read(Path(LOCAL_BUILD_VIEW_PROOF_PATH),1024**2)
    if hashlib.sha256(view_proof_body).hexdigest() != LOCAL_BUILD_VIEW_PROOF_SHA256:
        raise ValueError('actual Root plain-build-view proof changed')
    view_proof = dv_json(view_proof_body)
    if (view_proof.get('destination') != str(upstream/'dist'/DOVI_SOURCE_ROOT)
            or view_proof.get('genuineGitProvider') != LOCAL_PROVIDER_ROLES['dovi']['worktree']
            or view_proof.get('preparedSource') != str(upstream/'dist/dovi-inputs/authenticated-library')
            or view_proof.get('genuineGitProofSHA256') != LOCAL_GIT_PROOF_SHA256
            or view_proof.get('fileCount') != 209 or view_proof.get('gitDatabasePresent') is not False
            or view_proof.get('originalExportPreserved') is not True
            or view_proof.get('allRegular0644BodiesReadBackAgainstPreparedAndRealGit') is not True):
        raise ValueError('actual Root proof is not the fixed plain no-Git build view')
    registry,_ = _local_source_read(Path(LOCAL_PROVIDER_REGISTRY),1024**2)
    for role in ('wrapper','dovi'):
        _local_registry_row(registry,role,receipt[role]['registryRowSHA256'])
    wrapper = _local_git_identity('wrapper',receipt['wrapper'])
    dovi = _local_git_identity('dovi',receipt['dovi'])
    map_body,_ = _local_source_read(upstream/'Sources/BuildScripts/dovi-source-map.json',1024**2)
    if hashlib.sha256(map_body).hexdigest() != DOVI_MAP_SHA:
        raise ValueError('local source-map identity changed')
    mapping = dv_json(map_body)
    if mapping.get('commit') != DOVI_SOURCE_COMMIT or mapping.get('tree') != proof['tree']:
        raise ValueError('local source map/actual proof differs')
    _local_dovi_index(dovi['index'],mapping)
    dovi_root = Path(LOCAL_PROVIDER_ROLES['dovi']['worktree'])
    _local_dovi_index(_local_source_git(dovi_root,'ls-tree','-rz','--full-tree','HEAD'),mapping,tree=True)
    if _local_source_git(dovi_root,'ls-files','--others','--exclude-standard','-z').strip(bytes([0])):
        raise ValueError('untracked files in genuine Dovi provider')
    genuine = _local_dovi_bodies(dovi_root,mapping,True)
    build_view = _local_dovi_bodies(upstream/'dist'/DOVI_SOURCE_ROOT,mapping,False)
    if (not dv_equal(genuine,proof['files']) or not dv_equal(build_view,genuine)
            or not dv_equal(build_view,view_proof['files'])
            or hashlib.sha256(json.dumps(genuine,sort_keys=True,separators=(',',':')).encode()).hexdigest() != receipt['bodyMapSHA256']):
        raise ValueError('actual Git source/plain build view/Root proof body correspondence differs')
    return {'receiptSHA256':hashlib.sha256(receipt_body).hexdigest(),
            'inputsSHA256':hashlib.sha256(inputs_body).hexdigest(),
            'admissionSHA256':hashlib.sha256(admission_body).hexdigest(),
            'plainBuildViewProofSHA256':LOCAL_BUILD_VIEW_PROOF_SHA256,
            'wrapperTree':wrapper['tree'],'wrapperIndexSHA256':hashlib.sha256(wrapper['index']).hexdigest(),
            'doviIndexSHA256':hashlib.sha256(dovi['index']).hexdigest(),
            'bodyMapSHA256':receipt['bodyMapSHA256'],
            'wrapperRegistryRowSHA256':receipt['wrapper']['registryRowSHA256'],
            'doviRegistryRowSHA256':receipt['dovi']['registryRowSHA256']}


def _lp_git_metadata(canonical):
    common = canonical / '.git'
    fd = source_root_fd(common)
    os.close(fd)
    for relative in ('commondir', 'objects/info/alternates', 'objects/info/http-alternates'):
        candidate = common / relative
        _lp_need(not candidate.exists() and not candidate.is_symlink(), 'redirected LP Git metadata/object store')
    def walk_error(_error):
        raise ValueError('libplacebo virtual source: unreadable canonical Git metadata')
    for current, dirs, files in os.walk(common, followlinks=False, onerror=walk_error):
        for name in dirs + files:
            info = (Path(current) / name).lstat()
            _lp_need(not stat.S_ISLNK(info.st_mode) and (stat.S_ISDIR(info.st_mode) or stat.S_ISREG(info.st_mode)), 'redirected/special LP Git metadata')
            if stat.S_ISREG(info.st_mode):
                _lp_need(info.st_nlink == 1, 'hard-linked LP Git metadata')


def _lp_git_role(role, pin, mapping, registry):
    spec = LP_ROLES[role]
    root, canonical = Path(spec['worktree']), Path(spec['canonical'])
    _lp_git_metadata(canonical)
    for directory in (root, canonical, canonical / '.git', canonical / '.git/objects'):
        fd = source_root_fd(directory)
        os.close(fd)
    marker, _ = _local_source_read(root / '.git', 4096)
    _lp_need(marker.startswith(b'gitdir: ') and marker.endswith(b'\n'), 'LP worktree marker framing')
    admin_text = marker[len(b'gitdir: '):-1].decode('utf-8', 'strict')
    _lp_need(not any(c in admin_text for c in '\x00\t\r\n'), 'LP worktree marker path encoding')
    admin = Path(admin_text)
    _lp_need(admin.is_absolute() and admin.parent == canonical / '.git/worktrees'
             and re.fullmatch('[A-Za-z0-9_.-]+', admin.name), 'LP marker must select an immediate genuine canonical admin directory')
    fd = source_root_fd(admin)
    os.close(fd)
    backlink, _ = _local_source_read(admin / 'gitdir', 4096)
    common_marker, _ = _local_source_read(admin / 'commondir', 4096)
    _lp_need(backlink == (str(root / '.git') + '\n').encode('utf-8') and common_marker == b'../..\n', 'LP actual admin backlink/common marker')
    for name in ('alternates', 'http-alternates'):
        candidate = canonical / '.git/objects/info' / name
        _lp_need(not candidate.exists() and not candidate.is_symlink(), 'external LP object store refused')
    _lp_need(not (canonical / '.git/commondir').exists() and not (canonical / '.git/commondir').is_symlink(), 'redirected LP common directory')
    config = _local_source_git(canonical, 'config', '--local', '--no-includes', '--null', '--list')
    for entry in filter(None, config.split(b'\0')):
        name = entry.partition(b'\n')[0].decode('utf-8', 'strict').lower()
        _lp_need(not name.startswith(('include.', 'includeif.', 'url.', 'filter.', 'http.'))
                 and name not in ('core.alternaterefscommand', 'gc.recentobjectshook', 'core.worktree', 'extensions.worktreeconfig'), 'executable or redirected LP Git configuration')
    _lp_need(_local_source_git(root, 'rev-parse', '--show-toplevel').decode().strip() == str(root), 'genuine LP toplevel')
    common = Path(_local_source_git(root, 'rev-parse', '--git-common-dir').decode().strip())
    common = common if common.is_absolute() else root / common
    _lp_need(common.resolve() == canonical / '.git', 'LP genuine common directory')
    reported_admin = Path(_local_source_git(root, 'rev-parse', '--absolute-git-dir').decode().strip())
    _lp_need(reported_admin == admin and admin.resolve() == admin, 'LP Git-reported admin differs from prevalidated marker')
    _lp_need(_local_source_git(canonical, 'remote').decode().splitlines() == ['origin']
             and _local_source_git(canonical, 'config', '--get-all', 'remote.origin.url').decode().splitlines() == [spec['origin']], 'LP exact canonical origin')
    listing = _local_source_git(canonical, 'worktree', 'list', '--porcelain').decode('utf-8', 'strict')
    blocks = []
    for block in listing.strip().split('\n\n'):
        pairs = [line.partition(' ')[::2] for line in block.splitlines()]
        _lp_need(len({key for key, _ in pairs}) == len(pairs), 'duplicate LP Git registration field')
        value = dict(pairs)
        if value.get('worktree') == str(root):
            blocks.append(value)
    _lp_need(blocks == [{'worktree': str(root), 'HEAD': spec['commit'], 'branch': 'refs/heads/' + spec['branch']}], 'genuine LP registered worktree/HEAD/branch')
    selected = [line for line in registry.decode('utf-8', 'strict').splitlines()
                if len(line.split('\t')) >= 4 and line.split('\t')[3] == str(root)]
    _lp_need(bool(selected), 'LP registry row missing')
    row = selected[-1]
    fields = row.split('\t')
    _lp_need(len(fields) == 8 and fields[:4] == [spec['origin'], str(canonical), spec['branch'], str(root)]
             and fields[6] == 'active' and _lp_sha(row.encode()) == pin['registryRowSHA256'], 'latest active LP registry witness')
    _lp_need(_local_source_git(root, 'symbolic-ref', '-q', 'HEAD').decode().strip() == 'refs/heads/' + spec['branch']
             and _local_source_git(root, 'rev-parse', 'HEAD').decode().strip() == spec['commit']
             and _local_source_git(root, 'rev-parse', 'HEAD^{tree}').decode().strip() == spec['tree'], 'LP exact source commit/tree')
    for kind, oid in (('commit', spec['commit']), ('tree', spec['tree'])):
        body = _local_source_git(root, 'cat-file', kind, oid)
        _lp_need(hashlib.sha1(kind.encode() + b' ' + str(len(body)).encode() + b'\0' + body).hexdigest() == oid, 'LP raw commit/tree Git object')
    index = _local_source_git(root, 'ls-files', '--stage', '-z')
    _lp_need(index == _lp_role_index(mapping, role) and _lp_sha(index) == pin['indexSHA256']
             and not _local_source_git(root, 'diff', '--cached', '--name-only').strip()
             and _local_source_git(root, 'diff', '--no-ext-diff', '--no-textconv', '--binary') == b''
             and _local_source_git(root, 'ls-files', '--others', '--exclude-standard', '-z') == b'', 'LP complete index/clean source state')
    if role == 'parent':
        for name in LP_PARENT_GITLINKS:
            child = root / name
            _lp_need(not child.is_symlink() and (not child.exists() or (child.is_dir() and not any(child.iterdir()))), 'LP virtual links must not hide nested checkouts')
    return dict(spec, **pin)


def _lp_provider_snapshot(lane, upstream):
    if not _local_provider_mode(lane, upstream):
        return None
    _lp_need(lane == 'apple' and upstream == Path(LP_WORK), 'LP source provider exact local Apple wrapper')
    driver, _ = _local_source_read(upstream / 'Sources/BuildScripts/XCFrameworkBuild/main.swift', 2 * 1024**2)
    _lp_need(_lp_sha(driver) == LP_BUILD_DRIVER_SHA256, 'reviewed LP build driver binds demos=false')
    inputs = upstream / 'dist/placebo-inputs'
    admission_body, _ = _local_source_read(inputs / 'source-provider-admission.json', 2 * 1024**2)
    proof_body, _ = _local_source_read(inputs / 'full-build-view-proof.json', 2 * 1024**2)
    view = upstream / 'dist' / LP_SOURCE_ROOT
    map_body, _ = _local_source_read(view / '.vortx-libplacebo-source.json', 2 * 1024**2)
    mapping = _lp_map(map_body)
    admission = _lp_admission(admission_body, mapping, proof_body)
    for filename, checksum in (
        ('/Users/daksh/VortXTV/_recovery/resume-20261029/native-placebo-git-v1/RESULT.json', LP_PARENT_PROOF_SHA256),
        ('/Users/daksh/VortXTV/_recovery/resume-20261029/actual-placebo-gitlinks-v1.WJ5uFS/RESULT.json', LP_ACQUIRED_PROOF_SHA256),
        ('/Users/daksh/VortXTV/_recovery/resume-20261029/actual-placebo-gitlinks-v1.WJ5uFS/ROOT-READBACK.json', LP_ACQUIRED_READBACK_SHA256)):
        body, _ = _local_source_read(Path(filename), 2 * 1024**2)
        _lp_need(_lp_sha(body) == checksum, 'retained LP genuine acquisition proof changed')
    registry, _ = _local_source_read(Path(LOCAL_PROVIDER_REGISTRY), 2 * 1024**2)
    providers = {role: _lp_git_role(role, admission['roles'][role], mapping, registry) for role in LP_ROLES}
    directories = {str(parent) for name in mapping for parent in Path(name).parents if str(parent) != '.'}
    actual = set()
    fd = source_root_fd(view)
    os.close(fd)
    for current, dirs, files in os.walk(view, followlinks=False):
        for name in dirs:
            child = Path(current) / name
            _lp_need(not child.is_symlink() and child.relative_to(view).as_posix() in directories, 'extra or linked LP build-view directory')
        for name in files:
            actual.add((Path(current) / name).relative_to(view).as_posix())
    _lp_need(actual == set(mapping) | {'.vortx-libplacebo-source.json'}, 'exact853-body LP plain-view inventory')
    for name, row in mapping.items():
        owner = next((spec for role, spec in LP_ROLES.items() if role != 'parent' and name.startswith(spec['prefix'])), LP_ROLES['parent'])
        relative = name[len(owner['prefix']):]
        genuine, mode = _local_source_read(Path(owner['worktree']) / relative, 64 * 1024**2)
        _lp_check_body(genuine, row, mode)
        plain, plain_mode = _local_source_read(view / name, 64 * 1024**2)
        _lp_check_body(plain, row, plain_mode)
        _lp_need(genuine == plain, 'LP genuine-provider/plain-view correspondence')
    witness = {'schema': 2, 'profile': LP_SOURCE_PROFILE, 'currentBuildDriverSHA256': LP_BUILD_DRIVER_SHA256,
               'sourceMapUTF8': map_body.decode('utf-8'),
               'sourceMapSHA256': LP_SOURCE_MAP_SHA256, 'admissionUTF8': admission_body.decode('utf-8'),
               'admissionSHA256': _lp_sha(admission_body), 'fullBuildViewProofUTF8': proof_body.decode('utf-8'),
               'fullBuildViewProofSHA256': _lp_sha(proof_body), 'providers': providers,
               'demos': False, 'excludedUnresolvedGitlinks': LP_EXCLUDED_GITLINKS, 'completeNativeAcceptance': False}
    _lp_witness(witness)
    return witness


def _lp_source_paths(root, allowed_untracked):
    _lp_need(root == Path(LP_ROLES['parent']['worktree']) and allowed_untracked == {}, 'exact LP virtual parent/no generated files')
    witness = _lp_provider_snapshot('apple', Path(LP_WORK))
    mapping, _ = _lp_witness(witness)
    names = sorted(mapping)
    links = [{'path': name, 'commit': commit} for name, commit in sorted(LP_PARENT_GITLINKS.items())]
    identities = sorted((spec['prefix'], spec['commit'], spec['indexSHA256'], spec['trackedDiffSHA256'])
                        for spec in witness['providers'].values())
    return names, links, names, identities


def _source_capture_roots(lane, upstream, local, player=None):
    roots = [upstream]
    for directory in (upstream/'dist',upstream/'buildscripts/deps'):
        if directory.is_dir():
            roots.extend(path for path in directory.iterdir() if (path/'.git').exists())
    if local is not None:
        if lane != 'apple' or upstream != Path(LOCAL_PROVIDER_ROLES['wrapper']['worktree']):
            raise ValueError('local physical source roots selected another wrapper or lane')
        if (upstream/'dist'/DOVI_SOURCE_ROOT/'.git').exists() or (upstream/'dist'/DOVI_SOURCE_ROOT/'.git').is_symlink():
            raise ValueError('plain Dovi build view must never be a Git checkout')
        roots.append(Path(LOCAL_PROVIDER_ROLES['dovi']['worktree']))
        view = upstream / 'dist' / LP_SOURCE_ROOT
        if (view / '.git').exists() or (view / '.git').is_symlink():
            raise ValueError('LP plain build view must never be a Git checkout')
        roots.append(Path(LP_ROLES['parent']['worktree']))
    if player:
        _pp_need(local is not None and lane == 'apple' and upstream == Path(PLAYER_PLAIN_WORK), 'plain source capture needs exact admitted local wrapper')
        roots.extend(Path(name) for name in player)
    if len(set(roots)) != len(roots):
        raise ValueError('duplicate physical native source root')
    return roots


def source_root_fd(root):
    # Every ancestor is traversed without following links, including the root.
    if not root.is_absolute():
        raise ValueError('source root must be absolute')
    fd = os.open('/', os.O_RDONLY | os.O_DIRECTORY)
    try:
        for part in root.parts[1:]:
            following = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=fd)
            os.close(fd)
            fd = following
        return fd
    except BaseException:
        os.close(fd)
        raise


def source_parent_fd(rootfd, name):
    parts = source_name(name).split('/')
    fd = os.dup(rootfd)
    try:
        for part in parts[:-1]:
            following = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=fd)
            os.close(fd)
            fd = following
        return fd, parts[-1]
    except BaseException:
        os.close(fd)
        raise


class SourceHashReader:
    def __init__(self, stream):
        self.stream, self.hash, self.bytes = stream, hashlib.sha256(), 0

    def read(self, size=-1):
        block = self.stream.read(size)
        self.hash.update(block)
        self.bytes += len(block)
        return block


def source_tar_row(archive, rootfd, prefix, name, limits):
    parent, leaf = source_parent_fd(rootfd, name)
    try:
        before = os.stat(leaf, dir_fd=parent, follow_symlinks=False)
        row = {'path': name}
        entry = tarfile.TarInfo(prefix + '/' + name)
        entry.uid = entry.gid = entry.mtime = 0
        entry.uname = entry.gname = ''
        if stat.S_ISLNK(before.st_mode):
            target = os.readlink(leaf, dir_fd=parent)
            # Validate complete virtual link closure before publishing the staged archive.
            if (not target or len(target.encode('utf-8')) > 4096 or target.startswith('/')
                    or '\\' in target or ':' in target or not target.isprintable()
                    or any(p.casefold() == '.git' for p in target.split('/'))):
                raise ValueError('unsafe native source symlink target')
            after = os.stat(leaf, dir_fd=parent, follow_symlinks=False)
            if (after.st_dev, after.st_ino, after.st_mtime_ns) != (before.st_dev, before.st_ino, before.st_mtime_ns):
                raise ValueError('source symlink changed during capture')
            data = target.encode()
            entry.type, entry.linkname, entry.mode = tarfile.SYMTYPE, target, 0o777
            row.update(kind='symlink', mode=0o777, bytes=len(data),
                       sha256=hashlib.sha256(data).hexdigest(), target=target)
            archive.addfile(entry)
        elif stat.S_ISREG(before.st_mode):
            fd = os.open(leaf, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
            with os.fdopen(fd, 'rb') as stream:
                opened = os.fstat(stream.fileno())
                if (not stat.S_ISREG(opened.st_mode) or opened.st_nlink != 1
                        or (opened.st_dev, opened.st_ino, opened.st_size) !=
                           (before.st_dev, before.st_ino, before.st_size)
                        or opened.st_size < 0 or opened.st_size > SOURCE_MAX_FILE):
                    raise ValueError('unsafe/replaced opened native source file')
                entry.size, entry.mode = opened.st_size, 0o755 if opened.st_mode & 0o111 else 0o644
                reader = SourceHashReader(stream)
                archive.addfile(entry, reader)
                after = os.fstat(stream.fileno())
            if (reader.bytes != opened.st_size or after.st_size != opened.st_size
                    or after.st_mtime_ns != opened.st_mtime_ns):
                raise ValueError('source changed during capture')
            row.update(kind='file', mode=entry.mode, bytes=reader.bytes, sha256=reader.hash.hexdigest())
            limits[1] += reader.bytes
        else:
            raise ValueError('unsupported source object')
        limits[0] += 1
        if limits[0] > SOURCE_MAX_ENTRIES or limits[1] > SOURCE_MAX_TOTAL:
            raise ValueError('source profile limit exceeded')
        return row
    finally:
        os.close(parent)


def source_archive(path, rows):
    limits, result = [0, 0], []
    with path.open('xb') as raw, gzip.GzipFile(fileobj=raw, mode='wb', mtime=0) as compressed:
        with tarfile.open(fileobj=compressed, mode='w|', format=tarfile.PAX_FORMAT) as archive:
            for root, prefix, names in rows:
                fd = source_root_fd(root)
                try:
                    result.append([source_tar_row(archive, fd, prefix, name, limits) for name in names])
                finally:
                    os.close(fd)
    return result


def producer_archive(path, entries):
    rows = []
    with path.open('xb') as raw, gzip.GzipFile(fileobj=raw, mode='wb', mtime=0) as compressed:
        with tarfile.open(fileobj=compressed, mode='w|', format=tarfile.PAX_FORMAT) as archive:
            for name, data, mode in entries:
                entry = tarfile.TarInfo('producer/' + name)
                entry.uid = entry.gid = entry.mtime = 0
                entry.uname = entry.gname = ''
                entry.size, entry.mode = len(data), mode
                archive.addfile(entry, io.BytesIO(data))
                rows.append({'path': name, 'kind': 'file', 'mode': mode,
                             'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest()})
    return rows


def source_link_closure(files):
    links = {row['path'].casefold(): row['target'] for row in files if row['kind'] == 'symlink'}
    for name, target in links.items():
        done = name.split('/')[:-1]
        pending, expansions = target.split('/'), 0
        while pending:
            part = pending.pop(0)
            if part in ('', '.'):
                continue
            if part == '..':
                if not done:
                    raise ValueError('source symlink graph escapes component')
                done.pop()
                continue
            candidate = '/'.join(done + [part]).casefold()
            if candidate in links:
                expansions += 1
                if expansions > 40:
                    raise ValueError('source symlink graph cycle/depth exceeds profile')
                pending = links[candidate].split('/') + pending
            else:
                done.append(part)


def current_source_evidence(lane, out, upstream, roots, legacy, local=None, placebo=None, player=None):
    # Invalid/interrupted snapshots stay in an owned temporary directory and are
    # removed before the workflow's always-upload step can retain partial data.
    names = ('producer-inputs-v2.tar.gz', 'native-sources-v2.tar.gz', 'source-format-v2.json')
    if any((out / name).exists() or (out / name).is_symlink() for name in names):
        raise ValueError('refusing an existing v2 source receipt')
    with tempfile.TemporaryDirectory(prefix='.source-evidence-v2-', dir=out) as temporary:
        staged = Path(temporary)
        capture_current_source_evidence(lane, out, upstream, roots, legacy, staged, local, placebo, player)
        for name in names:
            os.replace(staged / name, out / name)


def capture_current_source_evidence(lane, out, upstream, roots, legacy, staged, local=None, placebo=None, player=None):
    if _local_provider_snapshot(lane,upstream) != local:
        raise ValueError('local source provider changed after legacy receipt')
    if _lp_provider_snapshot(lane, upstream) != placebo:
        raise ValueError('LP source providers/view changed after legacy receipt')
    if _pp_provider_snapshot(lane, upstream) != (player or {}):
        raise ValueError('full player source proof/body changed after legacy receipt')
    app = Path(os.environ['GITHUB_WORKSPACE'])
    commit = legacy['appSourceCommit']
    if (not re.fullmatch(r'[0-9a-f]{40}', commit) or app.is_symlink()
            or app.resolve() != app.absolute()
            or source_git(app, 'rev-parse', 'HEAD').decode().strip() != commit):
        raise ValueError('source evidence app identity differs')
    if not isinstance(legacy['workflowRef'], str) or not re.fullmatch(
            r'VortXTV/VortX/\.github/workflows/[A-Za-z0-9_.-]+\.yml@refs/(?:heads|tags)/[A-Za-z0-9_./-]+',
            legacy['workflowRef']):
        raise ValueError('unexpected public producer workflow ref')
    expected_wrapper = {'apple': '2103893078c5e339073b11737b86f7f22b9c4491',
                        'android': 'fcf6745703dc1265bca88f12fee8fc355ddf251e'}[lane]
    if (upstream.resolve() != upstream.absolute() or (local is None and not upstream.is_relative_to(app))
            or legacy['sources'][0]['commit'] != expected_wrapper):
        raise ValueError('source evidence wrapper identity differs')
    manifest = out / 'reviewed-inputs.sha256'
    inputs = {}
    for line in manifest.read_text().splitlines():
        value, name = line.split('  ', 1)
        if name in inputs or not re.fullmatch(r'[0-9a-f]{64}', value):
            raise ValueError('duplicate or malformed recipe hash')
        inputs[source_name(name)] = value
    if set(inputs) != CURRENT_RECIPE_PATHS:
        raise ValueError('not the exact 37-input finite-reference-reader/dovi source family')
    names = sorted(inputs | {'scripts/native-media-hosted/inputs.sha256': digest(manifest),
                             '.github/workflows/native-media-candidates.yml': None})
    entries = []
    appfd = source_root_fd(app)
    try:
        for name in names:
            tree = source_git(app, 'ls-tree', '-z', commit, '--', name).decode().rstrip('\0')
            identity, found = tree.split('\t', 1)
            mode, kind, oid = identity.split()
            if found != name or kind != 'blob' or mode not in ('100644', '100755'):
                raise ValueError('unexpected immutable producer blob identity')
            size = int(source_git(app, 'cat-file', '-s', oid))
            if size > SOURCE_MAX_FILE:
                raise ValueError('producer blob exceeds profile')
            data = source_git(app, 'cat-file', 'blob', oid)
            parent, leaf = source_parent_fd(appfd, name)
            try:
                fd = os.open(leaf, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
                with os.fdopen(fd, 'rb') as stream:
                    live = os.fstat(stream.fileno())
                    if (not stat.S_ISREG(live.st_mode) or live.st_nlink != 1
                            or live.st_size != len(data)
                            or (0o755 if live.st_mode & 0o111 else 0o644) != int(mode[-3:], 8)
                            or stream.read(SOURCE_MAX_FILE + 1) != data):
                        raise ValueError('producer differs from immutable blob')
            finally:
                os.close(parent)
            if name in inputs and hashlib.sha256(data).hexdigest() != inputs[name]:
                raise ValueError('producer differs from reviewed input')
            if name == 'scripts/native-media-hosted/inputs.sha256' and data != manifest.read_bytes():
                raise ValueError('retained input manifest differs from producer')
            entries.append((name, data, int(mode[-3:], 8)))
    finally:
        os.close(appfd)
    producer_rows = producer_archive(staged / 'producer-inputs-v2.tar.gz', entries)
    expected = CURRENT_SOURCE_ROOTS[lane]
    if (len(legacy['sources']) != len(expected)
            or {row['directory']: row['commit'] for row in legacy['sources']} != expected):
        raise ValueError('unexpected native source root or revision')
    native_rows, groups, boundaries = [], [], []
    for index, (root, old) in enumerate(zip(roots, legacy['sources'], strict=True)):
        expected_path = _source_expected_root(lane,upstream,old['directory'],index,local)
        if root != expected_path or root.resolve() != root.absolute():
            raise ValueError('native source root escapes its exact profile path')
        plain = (player or {}).get(str(root))
        if plain is not None:
            proof, _, _ = _pp_witness(plain)
            _pp_need(old['commit'] == proof['baseCommit'] and _pp_sha(_pp_legacy(plain)) == old['trackedDiffSHA256'], 'explicit legacy plain-source lineage')
        elif (source_git(root, 'rev-parse', 'HEAD').decode().strip() != old['commit']
                or hashlib.sha256(source_git(root, 'diff', '--no-ext-diff', '--no-textconv', '--binary')).hexdigest() != old['trackedDiffSHA256']):
            raise ValueError('native source changed after legacy receipt')
        allowed = CURRENT_UNTRACKED_FILES[lane][old['directory']]
        names, gitlinks, tracked, nested_identities = (_pp_source_paths(root, plain, allowed) if plain is not None else source_paths(root, allowed))
        if old['directory'] == OPENSSL_ROOT:
            observed_gitlinks = {row['path']: row['commit'] for row in gitlinks}
            if observed_gitlinks != OPENSSL_GITLINKS:
                raise ValueError('OpenSSL source Gitlink map differs from the pinned root tree')
        boundaries.append((root, old, allowed, (names, gitlinks, tracked, nested_identities)))
        groups.append({'receiptIndex': index, 'directory': old['directory'],
                       'commit': old['commit'], 'root': 'source-' + str(index), 'gitlinks': gitlinks})
        body_root = root
        if plain is not None:
            groups[-1]['playerPlainSource'] = plain
        if placebo is not None and old['directory'] == LP_SOURCE_ROOT:
            groups[-1]['placeboSource'] = placebo
            body_root = upstream / 'dist' / LP_SOURCE_ROOT
        native_rows.append((body_root, groups[-1]['root'], names))
    inventories = source_archive(staged / 'native-sources-v2.tar.gz', native_rows)
    for (root, old, allowed, boundary), files in zip(boundaries, inventories, strict=True):
        plain = (player or {}).get(str(root))
        if plain is not None:
            _pp_need(_pp_source_paths(root, plain, allowed) == boundary and _pp_sha(_pp_legacy(plain)) == old['trackedDiffSHA256'], 'complete plain-source identity/membership conserved during capture')
        elif (source_git(root, 'rev-parse', 'HEAD').decode().strip() != old['commit']
                or hashlib.sha256(source_git(root, 'diff', '--no-ext-diff', '--no-textconv', '--binary')).hexdigest() != old['trackedDiffSHA256']
                or source_paths(root, allowed) != boundary):
            raise ValueError('native source identity/membership changed during capture')
        actual = {row['path']: row for row in files}
        if placebo is not None and old['directory'] == LP_SOURCE_ROOT:
            mapping, _ = _lp_witness(placebo)
            _lp_need(len(files) == len(mapping) and set(actual) == set(mapping), 'captured LP source membership differs')
            for name, pin in mapping.items():
                _lp_need(actual[name] == {'path': name, 'kind': 'file',
                         'mode': 0o755 if pin['gitMode'] == '100755' else 0o644,
                         'bytes': pin['bytes'], 'sha256': pin['sha256']}, 'captured LP bytes/mode differ from the authenticated map')
        for name, value in allowed.items():
            if actual.get(name, {}).get('kind') != 'file' or actual[name]['sha256'] != value:
                raise ValueError('recipe-created source bytes differ from exact profile')
        source_link_closure(files)
        for row in files:
            row['tracked'] = row['path'] in boundary[2]
        if plain is not None:
            _pp_inventory(files, plain, allowed)
    actual_roots = _source_capture_roots(lane,upstream,local,player)
    if set(actual_roots) != set(roots) or len(actual_roots) != len(roots):
        raise ValueError('native source root set changed during capture')
    for group, files in zip(groups, inventories, strict=True):
        group['files'] = files
    required_pins = dict(CURRENT_NATIVE_PINS)
    if lane == 'apple':
        required_pins['libdovi-3.4.0-source'] = DOVI_SOURCE_COMMIT
        required_pins['lcms2-prerelease-candidate'] = '1315434113566bcf3eb46c2485fcc1c0a56ab806'
        required_pins['openssl-4.1.0-source'] = '2f4e3a5fec05394068cfa7379890ab552483a8a6'
    for name, pin in required_pins.items():
        if len([row for row in groups if row['commit'] == pin]) != 1:
            raise ValueError('missing/ambiguous required native source pin: ' + name)
    mpv = next(row for row in groups if row['commit'] == CURRENT_NATIVE_PINS['mpv'])
    actual = {row['path']: row for row in mpv['files']}
    if any(actual.get(name, {}).get('kind') != 'file'
           or actual[name]['sha256'] != value
           for name, value in (CURRENT_CANCEL_FILES | CURRENT_READER_MPV_FILES |
                               {'meson.build': CURRENT_READER_MPV_MESON[lane]}).items()):
        raise ValueError('native source snapshot lacks exact cancellation/finite-reader afterimages')
    ffmpeg = next(row for row in groups if row['commit'] == CURRENT_NATIVE_PINS['ffmpeg'])
    require_current_response_source({row['path']: row for row in ffmpeg['files']}, lane)
    outputs = {'apple': ['apple-candidate.tar.gz', 'apple-original-library-zips.tar',
                         'apple-artifact-gate.txt', 'apple-shaderc-original-all.zip',
                         'apple-shaderc-original-xcframework.zip',
                         'apple-shaderc-inputs.json', 'apple-openssl-builds.json',
                         'apple-crypto-source-gmp.tar.xz',
                         'apple-crypto-source-nettle.tar.gz',
                         'apple-crypto-source-gnutls.tar.xz',
                         'apple-crypto-release-sources.tar',
                         'apple-crypto-release-sources.json',
                         'apple-crypto-chain.json',
                         'apple-subtitle-source-unibreak.tar.gz',
                         'apple-subtitle-source-fribidi.tar.xz',
                         'apple-subtitle-source-harfbuzz.tar.xz', 'apple-bluray-source.tar.xz', 'apple-freetype-source.tar.gz',
                         'apple-subtitle-release-sources.tar',
                         'apple-subtitle-release-sources.json',
                         'apple-subtitle-builds.json', DOVI_OUTPUT, DOVI_VENDOR_OUTPUT],
               'android': ['libmpv-release-candidate.aar', 'android-artifact-evidence.json',
                           'android-corresponding-sources.tar.gz', 'android-build-configs.tar.gz']}[lane]
    archive_sources = crypto_source_outputs(out) if lane == 'apple' else None
    subtitle_archive_sources = subtitle_source_outputs(out) if lane == 'apple' else None
    def record(name):
        path = (staged if name in ('producer-inputs-v2.tar.gz', 'native-sources-v2.tar.gz') else out) / name
        if path.is_symlink() or not path.is_file():
            raise ValueError('required current producer output is missing/linked')
        return {'name': name, 'sha256': digest(path), 'bytes': path.stat().st_size}
    if _local_provider_snapshot(lane,upstream) != local:
        raise ValueError('local source provider changed during native capture')
    if _lp_provider_snapshot(lane, upstream) != placebo:
        raise ValueError('LP source provider/view changed during native capture')
    if _pp_provider_snapshot(lane, upstream) != (player or {}):
        raise ValueError('full player source proof/body changed during native capture')
    source_metadata = {
        'schema': 2, 'sourceProfile': CURRENT_SOURCE_PROFILE, 'lane': lane,
        **{k: legacy[k] for k in ('appSourceCommit', 'runId', 'attempt', 'workflowRef')},
        'recipeManifestSHA256': digest(manifest), 'legacyReceiptSHA256': digest(out / 'result.json'),
        'producerArchive': record('producer-inputs-v2.tar.gz'),
        'nativeArchive': record('native-sources-v2.tar.gz'), 'producerFiles': producer_rows,
        'sources': groups, 'archiveSources': archive_sources,
        'subtitleArchiveSources': subtitle_archive_sources,
        'outputs': [record(name) for name in outputs]}
    if player:
        _pp_need(len((json.dumps(source_metadata, indent=2, sort_keys=True) + '\n').encode()) <= 32 * 1024**2, 'complete proof/source inventory fits existing source metadata bound; never truncate')
    save(staged / 'source-format-v2.json', source_metadata)


def receipt(lane, out, upstream, exit_code):
    local = _local_provider_snapshot(lane,upstream)
    placebo = _lp_provider_snapshot(lane,upstream)
    player = _pp_provider_snapshot(lane, upstream)
    roots = _source_capture_roots(lane,upstream,local,player)
    sources = []
    for index, path in enumerate(roots):
        patch = out / f'source-{index}.patch'
        if str(path) in player:
            patch.write_bytes(_pp_legacy(player[str(path)]))
            commit = PLAYER_PLAIN_SPECS[player[str(path)]['family']]['base']
        elif local is None:
            patch.write_text(run('git', '-C', str(path), 'diff', '--binary'))
            commit = run('git', '-C', str(path), 'rev-parse', 'HEAD').strip()
        else:
            patch.write_bytes(source_git(path,'diff','--no-ext-diff','--no-textconv','--binary'))
            commit = source_git(path,'rev-parse','HEAD').decode().strip()
        sources.append({'directory': _source_logical_name(path,upstream,local), 'commit': commit,
                        'trackedDiffSHA256': digest(patch)})
    legacy = {'schema': 1, 'lane': lane, 'buildExit': exit_code,
         'appSourceCommit': os.environ['GITHUB_SHA'], 'workflowRef': os.environ.get('GITHUB_WORKFLOW_REF'),
         'runId': os.environ['GITHUB_RUN_ID'], 'attempt': os.environ['GITHUB_RUN_ATTEMPT'],
         'sources': sources, 'runtimeSecurityTested': False, 'promotionEligible': False}
    save(out / 'result.json', legacy)
    if exit_code == 0:
        current_source_evidence(lane, out, upstream, roots, legacy, local, placebo, player)
    # build.log is still owned by the workflow's tee process until this shell exits.
    files = {str(path.relative_to(out)): digest(path) for path in sorted(out.iterdir())
             if path.is_file() and path.suffix != '.log'}
    save(out / 'artifact-sha256.json', files)


if __name__ == '__main__':
    if sys.argv[1] == 'android':
        if len(sys.argv) not in (5, 7) or (len(sys.argv) == 7 and sys.argv[5] != '--readelf'):
            raise SystemExit('android OUT UPSTREAM SDK [--readelf /absolute/path/to/llvm-readelf]')
        android(*(Path(value) for value in sys.argv[2:5]),
                readelf=Path(sys.argv[6]) if len(sys.argv) == 7 else None)
    elif sys.argv[1] == 'receipt':
        receipt(sys.argv[2], Path(sys.argv[3]), Path(sys.argv[4]), int(sys.argv[5]))
    elif sys.argv[1] == 'apple-shaderc-inputs':
        if len(sys.argv) != 3:
            raise SystemExit('apple-shaderc-inputs WORK')
        apple_shaderc_inputs(Path(sys.argv[2]))
    elif sys.argv[1] == 'apple-shaderc-receipt':
        if len(sys.argv) != 3:
            raise SystemExit('apple-shaderc-receipt INPUT_DIR')
        apple_shaderc_receipt(Path(sys.argv[2]))
    elif sys.argv[1] == 'apple-openssl-builds':
        if len(sys.argv) != 3:
            raise SystemExit('apple-openssl-builds WORK')
        apple_openssl_builds(Path(sys.argv[2]))
    elif sys.argv[1] == 'apple-openssl-receipt':
        if len(sys.argv) != 3:
            raise SystemExit('apple-openssl-receipt FILE')
        apple_openssl_receipt(Path(sys.argv[2]))
    elif sys.argv[1] == 'apple-subtitle-builds':
        if len(sys.argv) != 3:
            raise SystemExit('apple-subtitle-builds WORK')
        apple_subtitle_builds(Path(sys.argv[2]))
    elif sys.argv[1] == 'apple-subtitle-receipt':
        if len(sys.argv) != 3:
            raise SystemExit('apple-subtitle-receipt FILE')
        apple_subtitle_receipt(Path(sys.argv[2]))
    elif sys.argv[1] == 'apple-dovi-builds':
        if len(sys.argv) != 3: raise SystemExit('apple-dovi-builds WORK')
        apple_dovi_builds(Path(sys.argv[2]))
    elif sys.argv[1] == 'apple-dovi-receipt':
        if len(sys.argv) != 3: raise SystemExit('apple-dovi-receipt FILE')
        apple_dovi_receipt(Path(sys.argv[2]))
    elif sys.argv[1] == 'apple-sent-abi':
        if len(sys.argv) < 3 or len(sys.argv[3:]) % 2:
            raise SystemExit('apple-sent-abi PACKAGE [--lipo /absolute/lipo] [--nm /absolute/nm]')
        tools = {}
        for flag, value in zip(sys.argv[3::2], sys.argv[4::2], strict=True):
            if flag not in ('--lipo', '--nm') or flag in tools:
                raise SystemExit('invalid or duplicate Apple inspection tool option')
            tools[flag] = Path(value)
        apple_sent_abi(Path(sys.argv[2]), lipo=tools.get('--lipo'), nm=tools.get('--nm'))
    else:
        raise SystemExit('unknown evidence mode')
