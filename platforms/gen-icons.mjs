// Rasterize the VortX favicon (webapp/public/favicon.svg, the canonical ember-X mark on the warm
// near-black tile) into the PNG app icons the webOS + Tizen packagers reference. Reproducible: re-run
// after the favicon changes. Uses the webapp's own `sharp` (a toolchain dependency), so no extra install.
//
//   node platforms/gen-icons.mjs
//
// Writes:
//   platforms/webos/icon.png       (80x80  - webOS appinfo `icon`)
//   platforms/webos/largeIcon.png  (130x130 - webOS appinfo `largeIcon`)
//   platforms/tizen/icon.png       (117x117 - Tizen config.xml `icon`)
//
// Store-submission icon sets (multiple sizes, the 512x423 Tizen store tile, etc.) are a follow-up.

import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";
import { readFileSync } from "node:fs";

const here = dirname(fileURLToPath(import.meta.url));
const require = createRequire(resolve(here, "../webapp/package.json"));
const sharp = require("sharp");

const svg = readFileSync(resolve(here, "../webapp/public/favicon.svg"));

const targets = [
  { out: "webos/icon.png", size: 80 },
  { out: "webos/largeIcon.png", size: 130 },
  { out: "tizen/icon.png", size: 117 },
];

for (const { out, size } of targets) {
  await sharp(svg, { density: 384 })
    .resize(size, size, { fit: "cover" })
    .png()
    .toFile(resolve(here, out));
  console.log(`wrote ${out} (${size}x${size})`);
}
