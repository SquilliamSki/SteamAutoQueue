// A tiny stand-in for Steam's debug endpoint, so the tool can be tested
// without Steam. No dependencies: plain Node.js 18+.
//
//   node server.js <port> [ok|notready]
//
// GET /json lists pages like Steam does. A WebSocket to the SharedJSContext
// page accepts Runtime.evaluate and runs the expression against a fake
// SteamClient with a fixed download list. Each QueueAppUpdate call is printed
// to stdout as:  QUEUED <appid>

'use strict';
const http = require('http');
const crypto = require('crypto');
const vm = require('vm');

const PORT = Number(process.argv[2] || 18080);
const MODE = process.argv[3] || 'ok';

// appid 10: scheduled   20: scheduled   30: unscheduled
// 40: downloading now   50: finished
const ITEMS = [
  { appid: 10, completed: false, active: false, queue_index: -1, deferred_time: 1730000000 },
  { appid: 20, completed: false, active: false, queue_index: -1, deferred_time: 1730000500 },
  { appid: 30, completed: false, active: false, queue_index: -1, deferred_time: 0 },
  { appid: 40, completed: false, active: true, queue_index: 0, deferred_time: 0 },
  { appid: 50, completed: true, active: false, queue_index: -1, deferred_time: 0 },
];

async function evaluate(expression) {
  const sandbox = {
    setTimeout, console,
    SteamClient: {
      Downloads: {
        RegisterForDownloadItems(cb) { setTimeout(() => cb(true, ITEMS.map((i) => ({ ...i }))), 10); return { unregister() {} }; },
        QueueAppUpdate(id) { console.log('QUEUED ' + id); },
      },
    },
    appStore: { GetAppOverviewByAppID: (id) => ({ display_name: 'Game ' + id }) },
  };
  sandbox.window = sandbox;
  return await vm.runInNewContext(expression, sandbox);
}

function frame(text) {
  const body = Buffer.from(text);
  let head;
  if (body.length < 126) head = Buffer.from([0x81, body.length]);
  else if (body.length < 65536) { head = Buffer.alloc(4); head[0] = 0x81; head[1] = 126; head.writeUInt16BE(body.length, 2); }
  else { head = Buffer.alloc(10); head[0] = 0x81; head[1] = 127; head.writeBigUInt64BE(BigInt(body.length), 2); }
  return Buffer.concat([head, body]);
}

const server = http.createServer((req, res) => {
  if (req.url !== '/json') { res.statusCode = 404; res.end(); return; }
  const pages = MODE === 'notready' ? [] : [
    { title: 'Steam', type: 'page', url: 'https://steamloopback.host/x', webSocketDebuggerUrl: `ws://127.0.0.1:${PORT}/devtools/page/MAIN` },
    { title: 'SharedJSContext', type: 'page', url: 'https://steamloopback.host/index.html', webSocketDebuggerUrl: `ws://127.0.0.1:${PORT}/devtools/page/SJS` },
  ];
  res.setHeader('Content-Type', 'application/json');
  res.end(JSON.stringify(pages));
});

server.on('upgrade', (req, socket) => {
  if (req.url !== '/devtools/page/SJS') { socket.destroy(); return; }
  const accept = crypto.createHash('sha1').update(req.headers['sec-websocket-key'] + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest('base64');
  socket.write(`HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${accept}\r\n\r\n`);

  let buf = Buffer.alloc(0);
  socket.on('error', () => {});
  socket.on('data', async (chunk) => {
    buf = Buffer.concat([buf, chunk]);
    while (buf.length >= 2) {
      const op = buf[0] & 0x0f;
      let len = buf[1] & 0x7f, off = 2;
      if (len === 126) { len = buf.readUInt16BE(2); off = 4; }
      else if (len === 127) { len = Number(buf.readBigUInt64BE(2)); off = 10; }
      if (buf.length < off + 4 + len) return;
      const mask = buf.subarray(off, off + 4);
      const data = Buffer.from(buf.subarray(off + 4, off + 4 + len));
      for (let i = 0; i < data.length; i++) data[i] ^= mask[i % 4];
      buf = buf.subarray(off + 4 + len);
      if (op === 8) { socket.end(); return; }
      if (op !== 1) continue;

      const msg = JSON.parse(data.toString());
      // Real Steam sends unrelated events too; the tool must skip them.
      socket.write(frame(JSON.stringify({ method: 'Runtime.consoleAPICalled', params: {} })));
      let reply;
      try {
        const value = await evaluate(msg.params.expression);
        // Padding makes the reply big enough to arrive in several pieces.
        reply = { id: msg.id, result: { result: { type: 'object', value } }, padding: 'x'.repeat(70000) };
      } catch (e) {
        reply = { id: msg.id, result: { result: { type: 'object' }, exceptionDetails: { text: String(e) } } };
      }
      socket.write(frame(JSON.stringify(reply)));
    }
  });
});

server.listen(PORT, '127.0.0.1', () => console.log(`fake Steam listening on ${PORT} (${MODE})`));
