import http from 'node:http';
import net from 'node:net';
import { spawn, execFile } from 'node:child_process';
import { randomInt } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { createInterface } from 'node:readline';
import { WebSocketServer } from 'ws';
import { RTCPeerConnection, RTCRtpCodecParameters, MediaStreamTrack, RtpHeader, RtpPacket } from 'werift';

// Bind address: set RD_HOST to this Mac's Tailscale IP (100.x.y.z).
// Find it with `tailscale ip -4` or in the Tailscale app. See README.md.
const host = process.env.RD_HOST;
if (!host) {
  console.error('RD_HOST is not set. Set it to this Mac\'s Tailscale IP, e.g. RD_HOST=100.x.y.z node server.mjs');
  process.exit(1);
}
const authority = host + ':8421';
const protocol = 'tailscale-remote-desktop';
const page = await readFile(new URL('./viewer.html', import.meta.url));
let capture, input, source, active, display, stopping = false;
let received = 0, framesSent = 0, captureFps = 0;
function stop(code = 0) {
  if (stopping) return;
  stopping = true;
  active?.ws.terminate();
  web.close();
  ingest.close();
  source?.destroy();
  capture?.kill();
  input?.stdin.end(); // EOF releases pressed buttons.
  setTimeout(() => { input?.kill(); process.exit(code); }, 500);
}
function child(name, stdout = 'inherit') {
  const p = spawn('./' + name, [], { stdio: ['pipe', stdout, 'inherit'] });
  p.on('error', e => { console.error(name, e); stop(1); });
  p.stdin.on('error', e => { if (!stopping) console.error(name, e.message); });
  p.on('exit', (code, signal) => {
    console.log(name, 'exit', signal ?? code);
    if (!stopping) stop(1);
  });
  return p;
}
function sendDisplay(ws) {
  if (display && ws?.readyState === 1) ws.send(JSON.stringify(display));
}
function readDisplay(line) {
  const [width, height] = line.split(' ').map(Number);
  if (Number.isFinite(width) && width > 0 && Number.isFinite(height) && height > 0) {
    display = {t:'display', width, height};
    sendDisplay(active?.ws);
  }
}
function keyframe() {
  if (capture?.stdin.writable) capture.stdin.write('keyframe\n');
}
function releaseButtons() {
  if (input?.stdin.writable) input.stdin.write('{"t":"up","b":0}\n{"t":"up","b":1}\n');
}
const prefix = Buffer.from([0, 0, 0, 1]);
function* payloads(nal) {
  if (nal.length <= 1150) { yield nal; return; }
  const indicator = (nal[0] & 0xe0) | 28;
  for (let i = 1; i < nal.length; i += 1148) {
    const end = Math.min(i + 1148, nal.length);
    const flags = (i === 1 ? 128 : 0) | (end === nal.length ? 64 : 0);
    yield Buffer.concat([Buffer.from([indicator, flags | (nal[0] & 31)]), nal.subarray(i, end)]);
  }
}
function frame(data) {
  received++;
  const peer = active;
  if (!peer || peer.pc.connectionState !== 'connected') return;
  const timestamp = Number((data.readBigUInt64BE(0) * 90n) & 0xffffffffn);
  let start = data.indexOf(prefix, 8);
  while (start >= 0) {
    const next = data.indexOf(prefix, start + 4);
    const nal = data.subarray(start + 4, next < 0 ? data.length : next);
    if (nal.length) {
      for (const payload of payloads(nal)) {
        const marker = next < 0 && (nal.length <= 1150 || !!(payload[1] & 64));
        const header = new RtpHeader({ payloadType: 96, sequenceNumber: peer.seq,
          ssrc: peer.ssrc, timestamp, marker });
        peer.seq = (peer.seq + 1) & 65535;
        peer.track.writeRtp(new RtpPacket(header, payload));
      }
    }
    start = next;
  }
  framesSent++;
}
const ingest = net.createServer(socket => {
  if (source) { socket.destroy(); return; }
  source = socket;
  let buffer = Buffer.alloc(0);
  socket.on('data', chunk => {
    buffer = buffer.length ? Buffer.concat([buffer, chunk]) : chunk;
    while (buffer.length >= 4) {
      const n = buffer.readUInt32BE();
      if (n < 13 || n > 8 * 1024 * 1024) { socket.destroy(); return; }
      if (buffer.length < n + 4) break;
      frame(buffer.subarray(4, 4+n));
      buffer = buffer.subarray(4+n);
    }
  });
  socket.on('error', console.error);
  socket.on('close', () => { source = null; if (!stopping) stop(1); });
});
const web = http.createServer((req, res) => {
  res.setHeader('Cache-Control', 'no-store');
  if (req.headers.host !== authority || req.method !== 'GET') return res.writeHead(403).end();
  if (req.url === '/') return res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' }).end(page);
  if (req.url === '/stats.json') return res.writeHead(200, { 'Content-Type': 'application/json' })
    .end(JSON.stringify({captureFps, framesSent, peers: Number(active?.pc.connectionState === 'connected')}));
  res.writeHead(404).end();
});
const wss = new WebSocketServer({ noServer: true, maxPayload: 65536 });
web.on('upgrade', (req, socket, head) => {
  const protocols = String(req.headers['sec-websocket-protocol'] || '').split(',').map(s => s.trim());
  const reasons = [];
  if (req.url !== '/session') reasons.push('url');
  if (req.headers.host !== authority) reasons.push('host');
  if (req.headers.origin !== 'http://' + authority) reasons.push('origin');
  if (!protocols.includes(protocol)) reasons.push('protocol');
  if (active) reasons.push('active');
  if (stopping) reasons.push('stopping');
  if (reasons.length) {
    console.log('upgrade rejected:', reasons.join(','));
    return socket.destroy();
  }
  wss.handleUpgrade(req, socket, head, ws => wss.emit('connection', ws));
});
function validInput(m) {
  const ratio = x => Number.isFinite(x) && x >= 0 && x <= 1;
  switch (m.t) {
    case 'move': return ratio(m.x) && ratio(m.y);
    case 'down': case 'up': return m.b === 0 || m.b === 1;
    case 'text': return typeof m.s === 'string' && m.s.length >= 1 && m.s.length <= 2000;
    case 'key': return Number.isInteger(m.code) && m.code >= 0 && m.code <= 127 &&
      (m.mods === undefined || (Array.isArray(m.mods) && m.mods.length <= 4 &&
        m.mods.every(mod => ['cmd','opt','ctrl','shift'].includes(mod))));
    case 'wheel': return Number.isInteger(m.dy) && Math.abs(m.dy) <= 120 &&
      (m.dx === undefined || (Number.isInteger(m.dx) && Math.abs(m.dx) <= 120));
    default: return false;
  }
}
wss.on('connection', async ws => {
  const codec = new RTCRtpCodecParameters({ mimeType: 'video/H264', clockRate: 90000,
    payloadType: 96, parameters: 'packetization-mode=1;profile-level-id=42e028;level-asymmetry-allowed=1',
    rtcpFeedback: [{type:'nack', parameter:'pli'}] });
  const pc = new RTCPeerConnection({ codecs: { video: [codec], audio: [] }, iceServers: [],
    iceUseDefaultStunServer: false, iceInterfaceAddresses: { udp4: host }, iceAdditionalHostAddresses: [host],
    iceUseIpv6: false, iceLite: true });
  const track = new MediaStreamTrack({ kind: 'video' });
  active = { pc, ws, track, seq: randomInt(65536), ssrc: randomInt(1, 0xffffffff) };
  sendDisplay(ws);
  const sender = pc.addTransceiver(track, { direction: 'sendonly' }).sender;
  sender.onPictureLossIndication.subscribe(keyframe);
  let readingClipboard = false;
  let answered = false, lastPing = Date.now();
  const watchdog = setInterval(() => { if (Date.now() - lastPing > 15000) ws.terminate(); }, 3000);
  ws.on('error', e => { console.error(e.message); ws.terminate(); });
  ws.on('close', () => {
    clearInterval(watchdog);
    active = null;
    releaseButtons();
    track.stop();
    pc.close().catch(console.error);
  });
  pc.connectionStateChange.subscribe(state => {
    if (state === 'connected') keyframe();
    if (state === 'failed') ws.terminate();
    if (state === 'disconnected') releaseButtons();
  });
  ws.on('message', async raw => {
    try {
      const m = JSON.parse(raw);
      if (m.t === 'ping') {
        lastPing = Date.now();
        ws.send(JSON.stringify({t:'pong', id:m.id}));
      } else if (m.t === 'answer' && !answered && typeof m.sdp === 'string') {
        answered = true;
        await pc.setRemoteDescription({type:'answer', sdp:m.sdp});
      } else if (m.t === 'clipboard' && pc.connectionState === 'connected' && !readingClipboard) {
        readingClipboard = true;
        execFile('/usr/bin/pbpaste', ['-Prefer', 'txt'], {
          encoding: 'utf8', maxBuffer: 65536, timeout: 3000, env: {...process.env, LC_ALL: 'en_US.UTF-8'}
        }, (error, result) => {
          readingClipboard = false;
          if (ws.readyState === 1) ws.send(JSON.stringify({t:'clipboard', text:error ? null : result}));
        });
      } else if (pc.connectionState === 'connected' && validInput(m)) {
        if (input.stdin.writableLength > 256 * 1024) return ws.terminate();
        input.stdin.write(JSON.stringify(m) + '\n');
      }
    } catch (e) { console.error(e.message); ws.terminate(); }
  });
  try {
    await pc.setLocalDescription(await pc.createOffer());
    if (ws.readyState === 1) ws.send(JSON.stringify({t:'offer', sdp:pc.localDescription.sdp}));
  } catch (e) { console.error(e.message); ws.terminate(); }
});
let before = performance.now(), previous = 0;
setInterval(() => {
  const now = performance.now();
  captureFps = Number(((received-previous)*1000/(now-before)).toFixed(1));
  console.log({received, captureFps, framesSent});
  before = now;
  previous = received;
}, 5000).unref();
for (const s of [ingest, web]) s.on('error', e => { console.error(e.message); stop(1); });
process.on('SIGINT', () => stop());
process.on('SIGTERM', () => stop());
ingest.listen(8422, '127.0.0.1', () => {
  web.listen(8421, host, () => {
    input = child('Input', 'pipe');
    createInterface({input:input.stdout}).on('line', readDisplay);
    capture = child('Capture');
    console.log('http://' + authority + '/');
  });
});
