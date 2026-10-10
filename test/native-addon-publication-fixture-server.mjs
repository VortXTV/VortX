import http from 'node:http';
import fs from 'node:fs';

// Synthetic wire data only. Each transport has a distinct manifest and serves resources locally.
const [portPath, holdStreamsPath] = process.argv.slice(2);
const server = http.createServer((request, response) => {
  const match = /^\/addon-(\d{2})\/(manifest\.json|stream\/movie\/fixture-movie\.json|catalog\/movie\/popular\.json)$/.exec(request.url);
  if (!match || Number(match[1]) >= 22) {
    response.writeHead(404, {'Content-Type': 'application/json'});
    response.end(JSON.stringify({error: 'fixture_not_found'}));
    return;
  }
  const index = Number(match[1]);
  const manifest = {
    id: `synthetic.addon.${match[1]}`, name: `Synthetic add-on ${match[1]}`, version: '1.0.0',
    resources: ['stream'], types: ['movie'], idPrefixes: ['fixture-'],
    behaviorHints: {configurable: true}, logo: 'https://synthetic.invalid/logo.png',
    fixtureExtension: {headers: {'X-Synthetic': `preserved-${index}`}, nested: [true, 7, null]},
  };
  if (index === 21) {
    manifest.resources.push('catalog');
    manifest.catalogs = [{id: 'popular', type: 'movie', name: 'Synthetic Catalog'}];
  }
  const body = match[2] === 'manifest.json' ? manifest
    : match[2].startsWith('stream/') ? {streams: [{name: `Synthetic source ${index}`, url: 'https://synthetic.invalid/video.mp4', behaviorHints: {proxyHeaders: {request: {'X-Synthetic': 'retained'}}}}]}
    : {metas: [{id: 'fixture-movie', type: 'movie', name: 'Synthetic Movie', poster: 'https://synthetic.invalid/poster.png'}]};
  const send = () => {
    response.writeHead(200, {'Content-Type': 'application/json'});
    response.end(JSON.stringify(body));
  };
  if (match[2].startsWith('stream/') && holdStreamsPath && fs.existsSync(holdStreamsPath)) {
    fs.writeFileSync(`${holdStreamsPath}.entered`, 'entered');
    const timer = setInterval(() => {
      if (response.destroyed) { clearInterval(timer); return; }
      if (!fs.existsSync(holdStreamsPath)) { clearInterval(timer); send(); }
    }, 5);
  } else send();
});
server.listen(0, '127.0.0.1', () => fs.writeFileSync(portPath, String(server.address().port)));
process.on('SIGTERM', () => { server.closeAllConnections(); server.close(() => process.exit(0)); });
