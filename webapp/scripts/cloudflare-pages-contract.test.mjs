import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const root = join(import.meta.dirname, "..");
const read = (path) => readFileSync(join(root, path), "utf8");

const npmVersion = "12.2.0";
const nodeVersion = "22.23.3";
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
  "packageManager must pin npm 12.2.0 with an integrity hash",
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
  "node scripts/cloudflare-pages-contract.test.mjs && node --test src/lib/*.test.mjs src/views/login.auth-adoption.test.mjs",
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

// HTTPS fetch permission does not authorize the separate WSS scheme used by live sync.
const headers = read("public/_headers");
const csp = headers.match(/^\s*Content-Security-Policy:\s*(.+)$/m)?.[1];
assert.ok(csp, "Pages must publish a content security policy");
const connectSources = csp.split(";").map((entry) => entry.trim()).find((entry) => entry.startsWith("connect-src "))?.split(/\s+/).slice(1) ?? [];
assert.ok(connectSources.includes("wss://api.vortx.tv"), "live account sync must be allowed to connect to the API WebSocket");
assert.ok(!connectSources.includes("wss:") && !connectSources.includes("*"), "the WebSocket allowance must stay limited to the VortX API");
// Plain HTTP is allowed only for the desktop shell: its numeric-loopback streaming server and Tauri's
// Windows IPC endpoint. Nothing else.
assert.ok(connectSources.includes("http://127.0.0.1:*"), "the desktop shell must reach its loopback streaming server");
assert.ok(!connectSources.some((source) => source === "http:" || /^http:\/\/(?!127\.0\.0\.1:\*$|ipc\.localhost$)/.test(source)),
  "no other plain-HTTP origin may be allowed");
assert.match(
  read("src/lib/vault.ts"),
  /new URL\("\/v1\/sync\/connect", API\)[\s\S]*?url\.protocol = "wss:"/,
  "the CSP allowance must match the actual live sync transport",
);
