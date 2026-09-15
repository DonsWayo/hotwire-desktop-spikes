#!/bin/bash
# Spike 1, made one command.
#
# The harness has been sitting unrun because it needed a server started, a page
# opened, and results read out of a JSONL file afterwards. This does all of
# that: starts the server, opens the page, waits while you sleep the display and
# toggle the network, then prints what happened.
#
# The measurement itself still needs a human, because display sleep and a lid
# close cannot be simulated. That hour is the whole point.
#
#   ./soak.sh            # one hour
#   ./soak.sh 15m        # or say how long

set -uo pipefail
cd "$(dirname "$0")"
DURATION="${1:-1h}"
PORT="${PORT:-4321}"

case "$DURATION" in
  *h) SECONDS_TOTAL=$(( ${DURATION%h} * 3600 )) ;;
  *m) SECONDS_TOTAL=$(( ${DURATION%m} * 60 )) ;;
  *s) SECONDS_TOTAL=${DURATION%s} ;;
  *)  SECONDS_TOTAL=$DURATION ;;
esac

rm -f results.jsonl
./run.sh >/tmp/spike01-server.log 2>&1 &
SRV=$!
cleanup() { kill "$SRV" 2>/dev/null; lsof -ti tcp:"$PORT" 2>/dev/null | xargs -r kill -9 2>/dev/null; }
trap cleanup EXIT

for _ in $(seq 1 60); do curl -s -o /dev/null --max-time 1 "http://127.0.0.1:$PORT/" && break; sleep 1; done

cat <<BANNER

  Spike 1 — does a webview hold a live connection to a loopback Puma?

  Running for $DURATION. The page is open now.

  While it runs, please:
    1. Sleep the display, and wake it
    2. Close the lid for ten minutes, and open it
    3. Turn Wi-Fi off, and on
    4. Leave it alone until the machine sleeps on its own

  A healthy hour ends with two connections opened and none closed. Every
  close is a finding. Press Ctrl-C to stop early; results are kept either way.

BANNER

open "http://127.0.0.1:$PORT/" 2>/dev/null || xdg-open "http://127.0.0.1:$PORT/" 2>/dev/null || \
  echo "  Open http://127.0.0.1:$PORT/ yourself."

END=$(( $(date +%s) + SECONDS_TOTAL ))
while [ "$(date +%s)" -lt "$END" ]; do
  LEFT=$(( END - $(date +%s) ))
  printf '\r  %02d:%02d left — sse %s  ws %s  ' \
    $(( LEFT / 60 )) $(( LEFT % 60 )) \
    "$(grep -c '"transport": *"sse"' results.jsonl 2>/dev/null | tr -d '\n' || echo 0)" \
    "$(grep -c '"transport": *"websocket"' results.jsonl 2>/dev/null | tr -d '\n' || echo 0)"
  sleep 5
done
printf '\n'

./report.sh
