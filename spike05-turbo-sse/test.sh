#!/bin/bash
# Starts the server, drives real browser engines at it, reports, stops.
set -uo pipefail
cd "$(dirname "$0")"
PORT="${PORT:-4322}"

./run.sh >/tmp/spike05-server.log 2>&1 &
SRV=$!
trap 'kill $SRV 2>/dev/null; lsof -ti tcp:$PORT | xargs -r kill -9 2>/dev/null' EXIT
for _ in $(seq 1 60); do curl -s -o /dev/null --max-time 1 "http://127.0.0.1:$PORT/" && break; done

NODE_PATH="$(ls -d /Users/juan.carracedo/Documents/GitHub/*/node_modules 2>/dev/null | head -1)" \
TARGET="http://127.0.0.1:$PORT/" \
  mise exec node@22 -- node test.js
