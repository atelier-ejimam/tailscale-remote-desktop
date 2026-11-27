#!/bin/bash
# If the remote desktop server (port 8421) is not running, relaunch it via
# run.command. Suitable for a periodic launchd / cron job on the Mac.
DIR="$(cd "$(dirname "$0")" && pwd)"
if ! /usr/sbin/lsof -nP -iTCP:8421 -sTCP:LISTEN >/dev/null 2>&1 && ! /usr/bin/pgrep -f "node server.mjs" >/dev/null 2>&1; then
  /usr/bin/open "$DIR/run.command"
  echo "$(date '+%Y-%m-%d %H:%M:%S') relaunched" >> "$DIR/watchdog.log"
fi
