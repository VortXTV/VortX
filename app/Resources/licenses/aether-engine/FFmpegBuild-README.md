# Third-party licenses

FFmpegBuild's shipped xcframeworks aggregate the following components. Apps
that distribute these frameworks must reproduce the applicable license texts
(for example on an acknowledgements screen or in bundled documentation).

| Component | Frameworks | License | Text |
| --- | --- | --- | --- |
| FFmpeg (libavcodec, libavformat, libavutil, libswresample, libswscale, libavfilter) | `AetherLibavcodec`, `AetherLibavformat`, `AetherLibavutil`, `AetherLibswresample`, `AetherLibswscale`, `AetherLibavfilter` | LGPL-2.1-or-later | [LGPL-2.1.txt](LGPL-2.1.txt) |
| dav1d | `AetherLibdav1d` | BSD-2-Clause | [dav1d.BSD-2-Clause.txt](dav1d.BSD-2-Clause.txt) |
| zimg | `AetherLibzimg` | WTFPL | [zimg.WTFPL.txt](zimg.WTFPL.txt) |
| libzvbi (library sources) | `AetherLibzvbi` | LGPL-2.0-or-later (conveyed under LGPL-2.1), `ure.c` under MIT | [LGPL-2.1.txt](LGPL-2.1.txt), [libzvbi-ure.MIT.txt](libzvbi-ure.MIT.txt) |

Notes:

- FFmpeg is configured without `--enable-gpl` and without `--enable-version3`,
  so the FFmpeg portions are plain LGPL-2.1-or-later. The exact configure
  flags are in [build.sh](../build.sh).
- libzvbi's tree contains three GPL-2 licensed source files
  (`packet-830.c`, `pdc.c`, `exp-vtx.c`). `build.sh` removes them from the
  library and replaces the two referenced entry points with LGPL stubs, so no
  GPL code is compiled into the shipped binaries. This is a modification of
  libzvbi in the sense of LGPL section 2; the modification is published in
  `build.sh` (`patch_zvbi`).
- The FFmpeg sources also carry a small set of local patches, which modify
  FFmpeg in the same LGPL section 2 sense. Each one is listed and explained
  in the top-level [README](../README.md#local-ffmpeg-patches) and applied by
  the `patch_ffmpeg*` functions in [build.sh](../build.sh), where its code is
  published.
- dav1d and zimg are built from unmodified upstream sources.
