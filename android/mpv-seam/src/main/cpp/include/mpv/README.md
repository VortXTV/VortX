The two headers here (`client.h`, `stream_cb.h`) are copied VERBATIM from mpv tag `v0.41.0`
(`https://github.com/mpv-player/mpv/blob/v0.41.0/include/mpv/client.h` and
`.../include/mpv/stream_cb.h`) -- the exact mpv release bundled inside the
`dev.jdtech.mpv:libmpv:1.0.0` AAR this project consumes, so the seam compiles against precisely the
client API version it links and runs against.

License: the mpv client API headers are ISC (the license grant is in each file's first lines; the
files themselves note that only the mpv CORE carries the GPL -- the client API is deliberately ISC).
These headers are compile-time inputs only; no mpv code is compiled or repackaged by this module.
