import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';
import { checkRuntime, stagedCsp, secureHtml } from './stage-security.mjs';

const root = dirname(dirname(fileURLToPath(import.meta.url)));
const read = path => readFileSync(join(root, path), 'utf8');
test('packaged TV inherits the actual Pages CSP before script/resource parsing', () => {
  const html = read('webapp/index.html'), policy = stagedCsp(read('webapp/public/_headers'));
  assert(!html.includes('http-equiv="Content-Security-Policy"'), 'before-control: Pages source relies on headers');
  const stage = secureHtml(html, policy);
  const position = stage.indexOf('http-equiv="Content-Security-Policy"');
  assert(position > stage.indexOf('<head>') && position < stage.indexOf('<meta charset='));
  assert(position < stage.indexOf('<script') && position < stage.indexOf('<link'));
  assert(stage.includes('media-src &#39;') === false, 'single quotes need no HTML attribute escaping');
  assert(policy.includes('connect-src') && policy.includes('https:') && policy.includes('worker-src') && policy.includes('blob:'));
  assert(policy.includes('frame-src https://www.youtube-nocookie.com'));
  assert.throws(() => secureHtml(stage, policy));
});
test('missing, duplicate, remote/inline script and active-object policies fail closed', () => {
  const header = read('webapp/public/_headers');
  for (const invalid of ['', header + '\nContent-Security-Policy: script-src *\n', header.replace("script-src 'self'", "script-src 'self' 'unsafe-inline'"), header.replace("script-src 'self'", 'script-src https:'), header.replace("object-src 'none'", 'object-src https:')]) assert.throws(() => stagedCsp(invalid));
  assert.throws(() => secureHtml('<html><body></body></html>', stagedCsp(header)));
});
test('TV-only HTTP provider compatibility cannot broaden script/frame/worker authority', () => {
  const header = read('webapp/public/_headers');
  const pages = header.match(/^\s*Content-Security-Policy:\s*(.+)$/m)[1];
  const parse = value => new Map(value.split(';').map(part => part.trim()).filter(Boolean).map(part => { const [key, ...values] = part.split(/\s+/); return [key, values]; }));
  const before = parse(pages), after = parse(stagedCsp(header));
  for (const key of ['media-src', 'connect-src', 'img-src']) {
    assert(!before.get(key).includes('http:'), 'Pages remains HTTPS-only');
    assert(after.get(key).includes('http:'), `${key} must admit arbitrary HTTP provider origins on packaged TV`);
    assert.deepEqual(after.get(key).filter(value => value !== 'http:'), before.get(key));
  }
  for (const key of ['script-src', 'frame-src', 'worker-src']) assert.deepEqual(after.get(key), before.get(key));
  for (const invalid of [header.replace("script-src 'self'", 'script-src http:'), header.replace('frame-src https://www.youtube-nocookie.com', 'frame-src https://untrusted.example'), header.replace("worker-src 'self' blob:", 'worker-src http:')]) assert.throws(() => stagedCsp(invalid));
});
test('shared package engine requirements gate old Node and wrong npm', () => {
  const manifest = JSON.parse(read('webapp/package.json'));
  assert.doesNotThrow(() => checkRuntime(manifest, '22.18.0', manifest.engines.npm));
  assert.doesNotThrow(() => checkRuntime(manifest, '26.7.0', manifest.engines.npm));
  for (const version of ['18.20.0', '22.17.9', '22.18.0-pre', 'unknown']) assert.throws(() => checkRuntime(manifest, version, manifest.engines.npm));
  assert.throws(() => checkRuntime(manifest, '26.7.0', '10.0.0'));
});
test('builder secures the stage before any SDK invocation; Tizen has no wildcard document-navigation grant', () => {
  const builder = read('platforms/build-tv.sh');
  assert(builder.indexOf('--check-runtime') < builder.indexOf('( cd "$WEBAPP" && npm run build )'));
  assert(builder.indexOf('"$STAGE" "$WEBAPP/public/_headers"') < builder.indexOf('ares-package "$STAGE"'));
  assert(builder.indexOf('"$STAGE" "$WEBAPP/public/_headers"') < builder.indexOf('tizen build-web'));
  const xml = read('platforms/tizen/config.xml');
  assert(!/<tizen:allow-navigation\b/.test(xml));
  assert(xml.includes('<access origin="*" subdomains="true"/>'), 'arbitrary provider networking is deliberately distinct from document navigation');
});
