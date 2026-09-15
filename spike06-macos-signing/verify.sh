#!/bin/bash
# Does a signed .app containing a Ruby interpreter actually run?
#
# Tested as a matrix, because the interesting answer is not "it works" but
# "which entitlements it needed". Every guide about embedding interpreters
# recommends disable-library-validation and allow-unsigned-executable-memory;
# this finds out whether Ruby genuinely requires them.

set -uo pipefail
cd "$(dirname "$0")"
FAIL=0
pass() { printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$*"; }   # a refusal is a finding, not a broken run
hard() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=1; }
note() { printf '  \033[36m•\033[0m %s\n' "$*"; }
step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

APP="$PWD/build/Spike.app"

run_case() {
  local label="$1" ents="${2:-}"
  step "$label"

  ENTITLEMENTS="$ents" ./bundle.sh >/tmp/spike06-bundle.log 2>&1 || {
    hard "bundling failed"; tail -5 /tmp/spike06-bundle.log | sed 's/^/      /'; return
  }
  note "$(grep -c 'signed' /tmp/spike06-bundle.log >/dev/null && grep 'signed .* nested' /tmp/spike06-bundle.log | tr -d ' ' | sed 's/^/nested binaries: /')"

  if codesign --verify --strict --deep "$APP" 2>/tmp/spike06-verify.log; then
    pass "signature verifies (--strict --deep)"
  else
    bad "signature does not verify"; sed 's/^/      /' /tmp/spike06-verify.log | head -4
  fi

  local flags
  # Entitlements have to be read off the *interpreter*, not the bundle: the
  # app's main executable is a shell script, and the process that dlopens the
  # C extensions is ruby. That is also where they have to be applied.
  flags=$(codesign -d --entitlements - "$APP/Contents/Resources/ruby/bin/ruby" 2>&1 \
          | grep -oE "com\.apple\.security\.cs\.[a-z-]+" | sort -u | paste -sd, -)
  note "entitlements on the interpreter: ${flags:-none}"
  codesign -d --verbose=2 "$APP/Contents/Resources/ruby/bin/ruby" 2>&1 | grep -qi "runtime" \
    && note "hardened runtime: on" || note "hardened runtime: NOT set"

  # The actual question: does the interpreter survive, and does Rails boot?
  local out rc
  out=$("$APP/Contents/MacOS/spike" -e '
    require "psych"; require "openssl"; require "sqlite3"
    require "./config/environment"
    require "rack/mock"
    Rails.application.routes.draw { get("/up", to: proc { [200, {"content-type"=>"text/plain"}, ["ok"]] }) }
    status, = Rails.application.call(Rack::MockRequest.env_for("http://127.0.0.1/up"))
    abort "status #{status}" unless status == 200
    puts "Rails #{Rails::VERSION::STRING} booted and served from a signed bundle"
  ' 2>&1)
  rc=$?

  if [ $rc -eq 0 ]; then
    pass "$(echo "$out" | tail -1)"
  elif [ $rc -eq 137 ] || [ $rc -eq 9 ]; then
    bad "killed by the kernel (exit $rc) — the hardened runtime rejected it"
  else
    bad "failed (exit $rc)"
    echo "$out" | tail -6 | sed 's/^/      /'
  fi
}

run_case "A. Hardened runtime, NO entitlements" ""
run_case "B. + allow-unsigned-executable-memory only" "$PWD/entitlements-jit.plist"
run_case "C. + disable-library-validation only" "$PWD/entitlements-libval.plist"
run_case "D. + both" "$PWD/entitlements-permissive.plist"

step "Bundle size"
[ -d "$APP" ] && note "$(du -sh "$APP" | cut -f1) total"

step "Result"
printf '  The case that passes with the fewest entitlements is the answer.\n'
printf '  Caveat: ad-hoc signing gives every binary a different Team ID, which is\n'
printf '  exactly what library validation rejects. A real Developer ID signs them\n'
printf '  all under ONE team, so this may not be needed with a real certificate.\n'
exit "$FAIL"
