# tailscale-remote-desktop

A tiny, self-hosted remote desktop for your own Mac, reachable **only inside
your Tailscale network**. Open one web page from your phone or another computer
on the same tailnet and you can see and operate your Mac's screen — no cloud
service, no account, no port forwarding.

Built for one job: checking and driving your own Mac from your phone while
you are away from your desk.

## How it works

```
Browser (phone / PC on your tailnet)
   │  WebRTC (H.264 video) + WebSocket (input, clipboard)
   ▼
server.mjs  (Node.js, binds to the Mac's Tailscale IP, port 8421)
   ├── Capture.swift  ScreenCaptureKit + VideoToolbox → H.264 over local TCP :8422
   └── Input.swift    CGEvent mouse / keyboard injection
```

- The web client is a single self-contained file (`viewer.html`): touch mode
  and mouse mode, long-press right-click, pinch zoom, an on-screen keyboard
  capture mode, a text-transfer box, clipboard pull from the Mac, WakeLock,
  and automatic reconnect.
- Video is WebRTC with host candidates only — no STUN/TURN, nothing leaves
  your tailnet.
- Only one viewer session at a time. The server validates the `Host` and
  `Origin` headers and a WebSocket subprotocol on every connection.

## Security model — read this first

**There is no password or login.** This tool is designed around one
assumption: *anything that can reach the Mac's Tailscale IP is trusted*,
because Tailscale itself is the access-control layer.

- Run it only on a tailnet whose devices you trust.
- **Never expose port 8421 to the public internet** (no port forwarding, no
  public reverse proxy). If you need access control beyond your tailnet, this
  is the wrong tool.
- Use Tailscale ACLs to limit which of your devices can reach TCP 8421 and
  the WebRTC UDP ports if you want a tighter setup.

## Requirements

- macOS (Apple silicon or Intel) with a logged-in GUI session
- [Tailscale](https://tailscale.com/) installed and signed in on the Mac and
  on the viewing device
- Node.js 20+ on `PATH` (and `npm`)
- Xcode Command Line Tools (`xcode-select --install`) for `swiftc`
- macOS permissions for the terminal / launcher you start it from:
  **Screen Recording** (for `Capture`) and **Accessibility** (for `Input`)

## Setup

```bash
git clone https://github.com/atelier-ejimam/tailscale-remote-desktop.git
cd tailscale-remote-desktop
```

Find your Mac's Tailscale IP:

```bash
tailscale ip -4        # e.g. 100.x.y.z
```

Start it (double-clicking `start.command` in Finder also works):

```bash
RD_HOST=100.x.y.z ./start.command
```

If the `tailscale` CLI is on `PATH`, `start.command` detects the IP
automatically and `RD_HOST` can be omitted. On first run it compiles the two
Swift helpers with `swiftc` and runs `npm install` (dependencies are only
`werift` and `ws`).

Then open `http://100.x.y.z:8421/` (your own IP) from a browser on the same
tailnet. That is all — no login.

### Keeping it running

- `run.command` — a double-clickable launcher that starts the server and logs
  to `server.log`. Suitable for starting it from a GUI session.
- `watchdog.sh` — if port 8421 is not listening, it relaunches via
  `run.command`. Call it periodically from launchd or cron if you want the
  server to come back after a crash.

## Configuration

| Variable  | Meaning                                                        |
| --------- | -------------------------------------------------------------- |
| `RD_HOST` | The Mac's Tailscale IP to bind to. Required (or auto-detected) |

Ports: TCP 8421 (HTTP + WebSocket, on the Tailscale IP), TCP 8422 (video
ingest, `127.0.0.1` only), plus WebRTC UDP on the Tailscale interface.

A quick health check from the Mac:

```bash
curl http://100.x.y.z:8421/stats.json
# {"captureFps":…, "framesSent":…, "peers":0|1}
```

## Layout

| File           | Role                                                                 |
| -------------- | -------------------------------------------------------------------- |
| `server.mjs`   | HTTP/WebSocket server, WebRTC peer, input validation, session control |
| `viewer.html`  | The whole web client (one file)                                       |
| `Capture.swift`| Screen capture → H.264 encoder, sends frames to the server           |
| `Input.swift`  | Mouse/keyboard injection via CGEvent; prints the display size         |
| `start.command`| Builds helpers if needed, installs deps, starts the server            |
| `run.command`  | Background launcher with logging                                      |
| `watchdog.sh`  | Relaunch-if-down helper                                               |

## License

MIT — see [LICENSE](LICENSE).
