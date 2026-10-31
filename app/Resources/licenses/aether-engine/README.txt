AetherEngine and the libraries it ships with in VortX for Apple TV

AetherEngine 7.53.0 (Vincent Herbst), LGPL-3.0 with an App Store / DRM exception:
  AetherEngine-LICENSE.txt, which refers to the GNU GPL in GPL-3.0.txt.
  Source: https://github.com/superuser404notfound/AetherEngine (tag 7.53.0)

FFmpegBuild 3.11.1, the AetherLib* frameworks:
  FFmpeg (libavcodec, libavformat, libavutil, libswresample, libswscale, libavfilter) under
  LGPL-2.1-or-later, built without GPL parts; libzvbi under LGPL-2.0-or-later (conveyed under
  LGPL-2.1) with ure.c under MIT; dav1d under BSD-2-Clause; zimg under WTFPL.
  See FFmpegBuild-README.md and the FFmpegBuild-*.txt files.
  Source and build script: https://github.com/superuser404notfound/FFmpegBuild (tag 3.11.1)

LibDovi 2.1.0, MIT: LibDovi-LICENSE.txt. https://github.com/superuser404notfound/LibDovi
SMBClient 0.3.1 (Kishikawa Katsumi), MIT: SMBClient-LICENSE.txt. https://github.com/kishikawakatsumi/SMBClient

The AetherLib* libraries are separate dynamic frameworks inside the app (Frameworks/AetherLib*.framework),
so they can be replaced with modified builds. VortX itself is GPL-3.0; its full source is at
https://github.com/VortXTV/VortX.
