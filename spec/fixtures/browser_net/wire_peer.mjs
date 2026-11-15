import {createServer} from 'node:net';
import {createHash} from 'node:crypto';
import {gzipSync} from 'node:zlib';

// Deliberate wire cases share one complete-header parser and owned socket set.
function writeFrame(socket, opcode, payload = Buffer.alloc(0), done) {
  const header = Buffer.alloc(payload.length < 126 ? 2 : payload.length < 65536 ? 4 : 10);
  header[0] = 0x80 | opcode;
  if (header.length === 2) header[1] = payload.length;
  else if (header.length === 4) { header[1] = 126; header.writeUInt16BE(payload.length, 2); }
  else { header[1] = 127; header.writeBigUInt64BE(BigInt(payload.length), 2); }
  socket.write(header);
  socket.write(payload, done);
}

function closeBody(code, reason = '') {
  const body = Buffer.alloc(2 + Buffer.byteLength(reason));
  body.writeUInt16BE(code); body.write(reason, 2);
  return body;
}

export async function wirePeer() {
  const sockets = new Set(), events = new Map(), websockets = new Map();
  const compressedBody = Buffer.from('decoded\0' + 'response-body-'.repeat(256) + '\xff', 'latin1');
  const compressed = gzipSync(compressedBody);
  const cors = 'Access-Control-Allow-Origin: *\r\nAccess-Control-Expose-Headers: *\r\n';
  const server = createServer(socket => {
    sockets.add(socket);
    let received = Buffer.alloc(0), route, counted = false, upgraded = false;
    function frames(chunk) {
      received = Buffer.concat([received, chunk]);
      while (received.length >= 2) {
        let length = received[1] & 127, header = 2;
        if (length === 126) { if (received.length < 4) return; length = received.readUInt16BE(2); header = 4; }
        if (length === 127) { if (received.length < 10) return; length = Number(received.readBigUInt64BE(2)); header = 10; }
        const masked = !!(received[1] & 128), mask = header;
        if (masked) header += 4;
        if (received.length < header + length) return;
        const opcode = received[0] & 15;
        const row = events.get(route);
        row.frames++; row.bytes += length;
        if (opcode === 8) {
          const body = Buffer.from(received.subarray(header, header + length));
          if (masked) for (let index = 0; index < length; index++) body[index] ^= received[mask + index % 4];
          if (!socket.writableEnded) { writeFrame(socket, 8, body); socket.end(); }
        }
        received = received.subarray(header + length);
      }
    }
    socket.on('error', () => {}); // A client abort is an expected observed outcome.
    socket.on('close', () => {
      sockets.delete(socket);
      if (counted) events.get(route).closed++;
    });
    socket.on('data', chunk => {
      if (upgraded) { frames(chunk); return; }
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
      } else if (route.startsWith('/ws-control/')) {
        const [, , id, action] = route.split('/'), entry = websockets.get(id);
        if (entry) {
          if (action === 'resume') entry.socket.resume();
          else if (action === 'reset') entry.socket.resetAndDestroy();
          else if (action === 'fin') { entry.socket.end(); entry.socket.resume(); }
          else if (action === 'close') { writeFrame(entry.socket, 8, closeBody(1000, 'bye')); entry.socket.end(); }
          else if (action === 'release') entry.release();
        }
        const body = entry ? 'ready' : 'missing';
        socket.end('HTTP/1.1 200 OK\r\n' + cors + 'Content-Length: ' + body.length + '\r\nConnection: close\r\n\r\n' + body);
      } else if (route.startsWith('/ws/')) {
        const [, , id, mode] = route.split('/');
        row.frames = 0; row.bytes = 0;
        if (mode === '403') { socket.end('HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n'); return; }
        const key = received.toString('latin1', 0, end).match(/^Sec-WebSocket-Key:\s*(.+)$/mi)?.[1].trim();
        const accept = mode === 'malformed' ? 'invalid' :
          createHash('sha1').update(key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest('base64');
        const opening = 'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ' + accept + '\r\n\r\n';
        if (mode === 'hold') {
          websockets.set(id, {socket, release() {
            upgraded = true; received = Buffer.alloc(0); socket.write(opening);
          }});
          return;
        }
        socket.write(opening);
        upgraded = true;
        received = Buffer.alloc(0);
        websockets.set(id, {socket, release() {
          if (mode === 'empty') { writeFrame(socket, 8); socket.end(); }
          else if (mode === '1000' || mode === '1001') { writeFrame(socket, 8, closeBody(Number(mode), 'peer')); socket.end(); }
          else if (mode === 'close-reset') writeFrame(socket, 8, closeBody(1000, 'bye'), () => socket.resetAndDestroy());
          else if (mode === 'large') {
            writeFrame(socket, 1, Buffer.from('first'));
            writeFrame(socket, 2, Buffer.from([0, 255]));
            writeFrame(socket, 2, Buffer.alloc(20 * 1024 * 1024, 97));
          }
        }});
        if (mode === 'paused') socket.pause();
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
