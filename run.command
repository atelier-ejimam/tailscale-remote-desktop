#!/bin/bash
# Double-clickable launcher (e.g. from Finder or a watchdog): starts the
# server in the background of a GUI session and logs to server.log.
cd "$(dirname "$0")" && ./start.command > server.log 2>&1
