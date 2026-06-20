# Anime4K shaders (bundled, MIT)

The `.glsl` files in this folder are the Anime4K real-time upscaling/restore
shaders by bloc97 and contributors, vendored unmodified from the upstream
project. They are loaded by the built-in libmpv player (`vo=gpu-next`) when the
"Anime4K" Video upscaling preset is selected. See `MPVMetalViewController`'s
`anime4kShaderPaths()` helper for how the chain is assembled.

- Upstream: https://github.com/bloc97/Anime4K
- License: MIT (see below)

## Bundled chain (Mode A "Fast": restore + upscale)

The curated chain is Anime4K's published "Mode A (Fast)" preset, copied verbatim
from the upstream low-end Mac/Linux template (`md/Template/GLSL_Mac_Linux_Low-end/
input.conf`, the `CTRL+1` binding). It uses the Medium (`_M`) and Small (`_S`) CNN
variants so it stays playable on Apple Silicon (Mac and the newer Apple TV 4K).
The Very Large (`_VL`) variants are sharper but too heavy for this hardware, so
they are deliberately not bundled.

1. `Anime4K_Clamp_Highlights.glsl`     - de-ring / highlight clamp pre-pass
2. `Anime4K_Restore_CNN_M.glsl`        - CNN restore (medium)
3. `Anime4K_Upscale_CNN_x2_M.glsl`     - CNN 2x upscale (medium)
4. `Anime4K_AutoDownscalePre_x2.glsl`  - auto-downscale guard (x2)
5. `Anime4K_AutoDownscalePre_x4.glsl`  - auto-downscale guard (x4)
6. `Anime4K_Upscale_CNN_x2_S.glsl`     - final CNN 2x upscale to target (small)

The order above is the order the shaders MUST be passed to mpv's `glsl-shaders`;
`anime4kShaderPaths()` returns them in exactly this sequence.

## Updating the shaders

To refresh from upstream, drop replacement files from
`https://github.com/bloc97/Anime4K` (the `glsl/Restore` and `glsl/Upscale`
folders) in here under the same file names, keeping the chain order above. Do not
rename them: the helper resolves each by exact file name from `Bundle.main`.

## MIT License

MIT License

Copyright (c) 2019-2021 bloc97

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
