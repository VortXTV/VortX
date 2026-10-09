import http from 'node:http';
import fs from 'node:fs';

const [fixturePath, portPath, delayMetaPath] = process.argv.slice(2);
// Keep wire integers exact: a normal JS parse/stringify silently rounds videoSize > 2^53.
const fixtures = JSON.parse(fs.readFileSync(fixturePath, 'utf8'), (_key, value, context) => {
  if (typeof value === 'number' && Number.isInteger(value) && !Number.isSafeInteger(value)) {
    if (!context?.source || !JSON.rawJSON) throw new Error('Fixture server requires lossless JSON source support (Node 22+)');
    return JSON.rawJSON(context.source);
  }
  return value;
});
const server = http.createServer((request, response) => {
  const resource = request.url.split('/')[1].split('.')[0];
  const body = fixtures[resource];
  const respond = () => {
    response.writeHead(body ? 200 : 404, {'Content-Type': 'application/json'});
    response.end(JSON.stringify(body ?? {error: 'fixture_not_found'}));
  };
  // The live-ABI harness creates this file only for the explicit card-action
  // race.  It gives the test a deterministic point to replace the registry
  // after resource admission but before the resolver can queue its mutation.
  if (resource === 'meta' && delayMetaPath && fs.existsSync(delayMetaPath)) {
    fs.writeFileSync(`${delayMetaPath}.entered`, '1');
    const waitForRelease = () => fs.existsSync(delayMetaPath) ? setTimeout(waitForRelease, 5) : respond();
    waitForRelease();
    return;
  }
  respond();
});
server.listen(0, '127.0.0.1', () => fs.writeFileSync(portPath, String(server.address().port)));
process.on('SIGTERM', () => server.close(() => process.exit(0)));
