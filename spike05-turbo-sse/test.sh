#!/bin/bash
# Starts the server, drives real browser engines at it, reports, stops.
set -uo pipefail
cd "$(dirname "$0")"
PORT="${PORT:-4322}"

./run.sh >/tmp/spike05-server.log 2>&1 &
SRV=$!
trap 'kill $SRV 2>/dev/null; lsof -ti tcp:$PORT | xargs -r kill -9 2>/dev/null' EXIT
for _ in $(seq 1 60); do curl -s -o /dev/null --max-time 1 "http://127.0.0.1:$PORT/" && break; done

# playwright is the only JavaScript dependency and it belongs to this spike, so
# it is installed here rather than borrowed from a sibling checkout. test.js
# resolves it from ./node_modules by node's own upward walk; no NODE_PATH.
if ! mise exec node@22 -- node -e 'require.resolve("playwright")' >/dev/null 2>&1; then
  echo "  installing playwright (first run only)"
  mise exec node@22 -- npm ci --no-audit --no-fund
fi

TARGET="http://127.0.0.1:$PORT/" \
  mise exec node@22 -- node test.js
