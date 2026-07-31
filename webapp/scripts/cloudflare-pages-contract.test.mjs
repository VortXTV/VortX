import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const root = join(import.meta.dirname, "..");
const read = (path) => readFileSync(join(root, path), "utf8");

const npmVersion = "11.17.0";
const nodeVersion = "22.18.0";
const rootDirectory = "webapp";
const buildCommand = "corepack install && corepack npm ci && corepack npm run build";
const buildOutput = "dist";
const skipInstall = "SKIP_DEPENDENCY_INSTALL=1";

const packageJson = JSON.parse(read("package.json"));
const lock = JSON.parse(read("package-lock.json"));
const readme = read("README.md");
const wrangler = read("wrangler.toml");

assert.match(
  packageJson.packageManager,
  new RegExp(`^npm@${npmVersion.replaceAll(".", "\\.")}\\+sha512\\.`),
  "packageManager must pin npm 11.17.0 with an integrity hash",
);
assert.equal(packageJson.engines.node, `>=${nodeVersion}`);
assert.equal(packageJson.engines.npm, npmVersion);
assert.equal(packageJson.devEngines.runtime.version, `>=${nodeVersion}`);
assert.equal(packageJson.devEngines.runtime.onFail, "error");
assert.equal(packageJson.devEngines.packageManager.version, npmVersion);
assert.equal(packageJson.devEngines.packageManager.onFail, "error");
assert.equal(lock.packages[""].engines.node, `>=${nodeVersion}`);
assert.equal(lock.packages[""].engines.npm, npmVersion);
assert.equal(read(".node-version").trim(), nodeVersion);
assert.equal(read(".npmrc").trim(), "engine-strict=true");
assert.equal(
  packageJson.scripts.test,
  "node scripts/cloudflare-pages-contract.test.mjs && node --test src/lib/*.test.mjs",
);
assert.equal(
  packageJson.scripts.deploy,
  "tsc && vite build && wrangler pages deploy dist --project-name=vortx-web",
);
assert.doesNotMatch(
  `${packageJson.scripts.test}\n${packageJson.scripts.deploy}`,
  /(^|[;&|]\s*)npm\s+run\b/,
  "scripts entered through Corepack must not escape to Node's bundled npm",
);

for (const [label, value] of [
  ["Pages root directory", rootDirectory],
  ["Pages build command", buildCommand],
  ["Pages build output", buildOutput],
  ["Pages dependency-install override", skipInstall],
]) {
  assert.ok(readme.includes(`\`${value}\``), `${label} is missing from README.md`);
  assert.ok(wrangler.includes(value), `${label} is missing from wrangler.toml guidance`);
}

assert.match(
  readme,
  /SKIP_DEPENDENCY_INSTALL[\s\S]*Pages build-system setting/,
  "README must identify SKIP_DEPENDENCY_INSTALL as a Pages build-system setting",
);
assert.ok(
  readme.includes("`wrangler.toml` cannot configure those Git-connected build settings"),
  "README must not imply Wrangler controls Git-connected Pages build settings",
);
assert.match(
  wrangler,
  /dashboard-only settings/,
  "Wrangler guidance must identify the dashboard-only settings",
);
