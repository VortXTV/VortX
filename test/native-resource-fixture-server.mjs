import http from 'node:http';
import fs from 'node:fs';

const [fixturePath, portPath] = process.argv.slice(2);
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
  response.writeHead(body ? 200 : 404, {'Content-Type': 'application/json'});
  response.end(JSON.stringify(body ?? {error: 'fixture_not_found'}));
});
server.listen(0, '127.0.0.1', () => fs.writeFileSync(portPath, String(server.address().port)));
process.on('SIGTERM', () => server.close(() => process.exit(0)));
