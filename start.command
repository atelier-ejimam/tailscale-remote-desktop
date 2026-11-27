#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

# Node.js 20+ must be available on PATH.
if ! command -v node >/dev/null 2>&1; then
    echo "Node.js 20+ is required but 'node' was not found on PATH." >&2
    exit 1
fi

# The server binds to this Mac's Tailscale IP. RD_HOST can be set explicitly;
# otherwise it is detected with the tailscale CLI when available.
if [[ -z "${RD_HOST:-}" ]] && command -v tailscale >/dev/null 2>&1; then
    RD_HOST="$(tailscale ip -4 2>/dev/null | head -n 1 || true)"
fi
if [[ -z "${RD_HOST:-}" ]]; then
    echo "Could not determine this Mac's Tailscale IP." >&2
    echo "Set it explicitly, e.g.:  RD_HOST=100.x.y.z ./start.command" >&2
    exit 1
fi
export RD_HOST

# Build the Swift helpers when missing or outdated.
for helper in Capture Input; do
    if [[ ! -x "$helper" || "$helper.swift" -nt "$helper" ]]; then
        opts=(-swift-version 5 -O)
        if [[ "$helper" == Capture ]]; then opts+=(-parse-as-library); fi
        xcrun swiftc "${opts[@]}" "$helper.swift" -o "$helper"
    fi
done

if [[ ! -d node_modules/werift || ! -d node_modules/ws ]]; then
    npm install --no-audit --no-fund
fi

echo "Open http://${RD_HOST}:8421/ from a device on the same tailnet. No login is required."
exec node server.mjs
