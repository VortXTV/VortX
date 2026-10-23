import { readFileSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

export function checkRuntime(manifest, nodeVersion, npmVersion) {
  npmVersion = npmVersion.trim();
  const minimum = /^>=(\d+)\.(\d+)\.(\d+)$/.exec(manifest.engines?.node ?? '');
  const current = /^(\d+)\.(\d+)\.(\d+)$/.exec(nodeVersion);
  if (!minimum || !current) throw new Error('TV builder requires explicit comparable Node engine versions');
  const required = minimum.slice(1).map(Number), actual = current.slice(1).map(Number);
  let comparison = 0;
  for (let index = 0; index < 3 && !comparison; index++) comparison = Math.sign(actual[index] - required[index]);
  if (comparison < 0) throw new Error(`TV builder requires Node ${manifest.engines.node}; got ${nodeVersion}`);
  if (!/^\d+\.\d+\.\d+$/.test(manifest.engines?.npm ?? '') || npmVersion !== manifest.engines.npm) throw new Error(`TV builder requires npm ${manifest.engines?.npm}; got ${npmVersion}`);
}

export function stagedCsp(headers) {
  const matches = [...headers.matchAll(/^\s*Content-Security-Policy:\s*([^\r\n]+)$/gmi)];
  if (matches.length !== 1) throw new Error('TV stage requires one authoritative Pages CSP');
  const csp = matches[0][1].trim();
  const policy = new Map();
  for (const part of csp.split(';').map(part => part.trim()).filter(Boolean)) {
    const [name, ...values] = part.split(/\s+/);
    if (policy.has(name)) throw new Error('TV stage refuses duplicate CSP directives');
    policy.set(name, values);
  }
  const scripts = policy.get('script-src');
  if (!scripts || scripts.length !== 1 || scripts[0] !== "'self'" || policy.get('object-src')?.join(' ') !== "'none'") throw new Error('TV stage refuses remote/inline/eval script or active object authority');
  if (policy.get('frame-src')?.join(' ') !== 'https://www.youtube-nocookie.com' || policy.get('worker-src')?.join(' ') !== "'self' blob:") throw new Error('TV stage refuses untrusted frame or worker authority');
  if (!policy.has('default-src') || !policy.has('base-uri') || !policy.has('form-action')) throw new Error('TV stage requires complete default/base/form CSP boundaries');
  // Preserve packaged-TV HTTP posters, direct media and HLS fetches; never broaden
  // script, iframe or worker authority. The authoritative Pages policy stays unchanged.
  for (const directive of ['media-src', 'connect-src', 'img-src']) {
    const values = policy.get(directive);
    if (!values) throw new Error(`TV stage requires explicit ${directive}`);
    if (!values.includes('http:')) values.push('http:');
  }
  return [...policy].map(([name, values]) => [name, ...values].join(' ')).join('; ');
}

export function secureHtml(html, csp) {
  if (/<meta\b[^>]*http-equiv\s*=\s*["']\s*content-security-policy/i.test(html)) throw new Error('TV stage already has a CSP; refusing ambiguous policy composition');
  const head = /<head\b[^>]*>/i.exec(html);
  if (!head) throw new Error('TV stage has no HTML head');
  // Put CSP immediately after the opening head, before metadata links or scripts.
  const index = head.index + head[0].length;
  const encoded = csp.replace(/&/g, '&amp;').replace(/"/g, '&quot;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
  return html.slice(0, index) + `\n    <meta http-equiv="Content-Security-Policy" content="${encoded}" />` + html.slice(index);
}

if (process.argv[1] && pathToFileURL(resolve(process.argv[1])).href === import.meta.url) {
  try {
    if (process.argv[2] === '--check-runtime') {
      if (process.argv.length !== 5) throw new Error('usage: stage-security.mjs --check-runtime <package.json> <npm-version>');
      checkRuntime(JSON.parse(readFileSync(process.argv[3], 'utf8')), process.versions.node, process.argv[4]);
    } else {
      if (process.argv.length !== 4) throw new Error('usage: stage-security.mjs <stage-directory> <Pages-headers>');
      const index = join(resolve(process.argv[2]), 'index.html');
      const csp = stagedCsp(readFileSync(process.argv[3], 'utf8'));
      const secured = secureHtml(readFileSync(index, 'utf8'), csp);
      writeFileSync(index, secured);
    }
  } catch (error) { console.error(`TV security: ${error.message}`); process.exitCode = 1; }
}
