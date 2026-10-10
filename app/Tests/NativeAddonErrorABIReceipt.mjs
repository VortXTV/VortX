import http from 'node:http';
import { spawn } from 'node:child_process';
const executable = process.argv[2];
if (!executable) throw new Error('fixture executable required');
const server = http.createServer((request, response) => {
  const kind = request.url.split('/')[1];
  if (kind === 'timeout') { setTimeout(() => response.end('{"streams":[]}'), 500); return; }
  response.statusCode = kind === 'malformed' ? 200 : Number(kind);
  response.end(kind === 'malformed' ? 'not-json' : '{}');
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
try {
  for (const kind of ['401', '429', '503', 'timeout', 'malformed']) {
    const output = await new Promise((resolve, reject) => {
      const child = spawn(executable, [String(server.address().port), kind]);
      let text = '';
      child.stdout.on('data', bytes => { text += bytes; });
      child.on('error', reject);
      child.on('close', code => code === 0 ? resolve(text) : reject(new Error(`fixture exit ${code}`)));
    });
    const value = JSON.parse(output), group = value.groups?.[0];
    const expected = /^\d+$/.test(kind) ? 'http' : kind;
    if (value.kind !== 'resource_result' || value.requestId !== 'fixture' || value.generation !== 1 ||
        group?.addonId !== 'fixture' || group.error?.code !== expected ||
        (expected === 'http' && group.error.status !== Number(kind)) ||
        (expected !== 'http' && group.error.status !== undefined)) throw new Error(`receipt mismatch ${kind}`);
    console.log(`PASS actual CABI resource=stream code=${group.error.code}${group.error.status ? ` status=${group.error.status}` : ''}`);
  }
} finally {
  server.closeAllConnections();
  await new Promise(resolve => server.close(resolve));
}
