import {createServer} from 'node:net';
import {gzipSync} from 'node:zlib';

// Raw response cases share one parser/dispatch seam with future WS upgrades.
export async function wirePeer() {
  const sockets = new Set(), events = new Map();
  const compressedBody = Buffer.from('decoded\0' + 'response-body-'.repeat(256) + '\xff', 'latin1');
  const compressed = gzipSync(compressedBody);
  const cors = 'Access-Control-Allow-Origin: *\r\nAccess-Control-Expose-Headers: *\r\n';
  const server = createServer(socket => {
    sockets.add(socket);
    let received = Buffer.alloc(0), route, counted = false;
    socket.on('error', () => {}); // A client abort is an expected observed outcome.
    socket.on('close', () => {
      sockets.delete(socket);
      if (counted) events.get(route).closed++;
    });
    socket.on('data', chunk => {
      received = Buffer.concat([received, chunk]);
      const end = received.indexOf('\r\n\r\n');
      if (end < 0 || counted) return;
      const [method, target] = received.toString('latin1', 0, end).split('\r\n')[0].split(' ');
      route = target.split('?')[0];
      counted = true;
      const row = events.get(route) ?? {opened: 0, closed: 0};
      events.set(route, row); row.opened++;
      if (method === 'OPTIONS') {
        socket.end('HTTP/1.1 204 No Content\r\n' + cors +
          'Access-Control-Allow-Methods: *\r\nAccess-Control-Allow-Headers: *\r\nConnection: close\r\n\r\n');
      } else if (route.startsWith('/events/')) {
        const entry = events.get('/' + route.slice('/events/'.length)) ?? {opened: 0, closed: 0};
        const body = JSON.stringify(entry);
        socket.end('HTTP/1.1 200 OK\r\n' + cors + 'Connection: close\r\nContent-Length: ' + Buffer.byteLength(body) + '\r\n\r\n' + body);
      } else if (route.startsWith('/headers/')) {
        // No headers until the requester cancels; close is the only completion.
      } else if (route.startsWith('/body/')) {
        socket.write('HTTP/1.1 200 OK\r\n' + cors + 'Content-Length: 999999\r\n\r\nfirst\n');
      } else if (route === '/gzip') {
        socket.end(Buffer.concat([Buffer.from('HTTP/1.1 200 OK\r\n' + cors +
          'Content-Encoding: gzip\r\nContent-Length: ' + compressed.length + '\r\nConnection: close\r\n\r\n'), compressed]));
      } else if (route === '/reset') {
        socket.write('HTTP/1.1 200 OK\r\n' + cors + 'Content-Length: 999999\r\n\r\npartial');
        events.get(route).reset = () => socket.resetAndDestroy();
      } else if (route === '/reset-now') {
        events.get('/reset')?.reset?.();
        socket.end('HTTP/1.1 200 OK\r\n' + cors + 'Content-Length: 0\r\nConnection: close\r\n\r\n');
      } else if (route === '/stream') {
        socket.write('HTTP/1.1 200 OK\r\n' + cors + 'Transfer-Encoding: chunked\r\n\r\n6\r\nfirst|\r\n');
        // A control request releases this response only after a public read.
        const row = events.get(route);
        row.release = () => socket.end('b\r\nsecond|tail\r\n0\r\n\r\n');
      } else if (route === '/release') {
        events.get('/stream')?.release?.();
        socket.end('HTTP/1.1 200 OK\r\n' + cors + 'Content-Length: 0\r\nConnection: close\r\n\r\n');
      } else {
        socket.end('HTTP/1.1 404 Not Found\r\n' + cors + 'Content-Length: 0\r\nConnection: close\r\n\r\n');
      }
    });
  });
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(0, '127.0.0.1', resolve); });
  return {url: `http://127.0.0.1:${server.address().port}`, events, compressedBody,
    async close() { for (const socket of sockets) socket.destroy(); await new Promise(resolve => server.close(resolve)); }};
}

if (import.meta.main) {
  const peer = await wirePeer();
  console.log('READY ' + peer.url);
  const finish = async () => { await peer.close(); process.exit(0); };
  process.once('SIGTERM', finish); process.once('SIGINT', finish);
}
