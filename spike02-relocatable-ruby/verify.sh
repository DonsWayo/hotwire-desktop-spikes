#!/bin/bash
# Does the built Ruby actually relocate, and does Rails boot from the new path?
#
# Three questions, in order of how cheaply they fail:
#   1. Does anything still link an absolute path into a package manager?
#   2. Does it run at all after being moved somewhere else entirely?
#   3. Does Rails boot from the moved copy?

set -uo pipefail
cd "$(dirname "$0")"

ORIGINAL="$PWD/build/out/ruby"
MOVED="$PWD/build/relocated/ruby"     # a deliberately different depth and name
FAIL=0

pass() { printf '  \033[32m✓\033[0m %s\n' "$*"; }
fail() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=1; }
step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

[ -x "$ORIGINAL/bin/ruby" ] || { echo "No build yet. Run ./build.sh first."; exit 1; }

# ---------------------------------------------------- 1. linkage
step "1. Linkage — nothing may point into a package manager"
BAD=$(find "$ORIGINAL" \( -name '*.bundle' -o -name '*.dylib' -o -name 'ruby' \) -type f 2>/dev/null | while read -r f; do
  otool -L "$f" 2>/dev/null | tail -n +2 | grep -E '/opt/homebrew|/usr/local/(opt|Cellar)' | sed "s|^|$(basename "$f"): |"
done)
if [ -z "$BAD" ]; then
  pass "no /opt/homebrew or /usr/local linkage in any binary or extension"
else
  fail "absolute package-manager paths found:"; echo "$BAD" | sed 's/^/      /'
fi

step "What psych and openssl actually link (the two that decide it)"
for ext in psych openssl; do
  f=$(find "$ORIGINAL" -name "$ext.bundle" | head -1)
  if [ -n "$f" ]; then
    echo "  $ext.bundle:"; otool -L "$f" | tail -n +2 | sed 's/^/    /'
  else
    echo "  $ext: built in statically (no .bundle) — good"
  fi
done

# ---------------------------------------------------- 2. relocation
step "2. Relocation — move it somewhere else entirely and run it"
rm -rf "$PWD/build/relocated"; mkdir -p "$PWD/build/relocated"
cp -R "$ORIGINAL" "$MOVED"

"$MOVED/bin/ruby" -v >/dev/null 2>&1 && pass "runs from the new path: $("$MOVED/bin/ruby" -v)" \
                                     || fail "will not run after being moved"

"$MOVED/bin/ruby" -e 'require "psych"; abort "psych broken" unless Psych.load("- 1") == [1]' 2>&1 \
  && pass "psych loads and parses (Rails cannot boot without this)" \
  || fail "psych failed — this alone makes the build unshippable"

"$MOVED/bin/ruby" -e 'require "openssl"; abort "digest wrong" unless OpenSSL::Digest::SHA256.hexdigest("x").length == 64; puts OpenSSL::OPENSSL_VERSION' \
  && pass "openssl works" || fail "openssl failed"

"$MOVED/bin/ruby" -e 'require "zlib"; require "json"; require "fiddle"; require "socket"' 2>&1 \
  && pass "zlib, json, fiddle, socket all load" || fail "a core extension failed to load"

"$MOVED/bin/ruby" -e 'puts RbConfig::CONFIG["prefix"]' | grep -q "relocated" \
  && pass "RbConfig prefix follows the binary (--enable-load-relative works)" \
  || fail "RbConfig still points at the build-time prefix"

# ---------------------------------------------------- 3. Rails
step "3. Rails — install and boot from the relocated copy"
export GEM_HOME="$PWD/build/relocated/gems"
export GEM_PATH="$GEM_HOME:$MOVED/lib/ruby/gems/3.4.0"
export PATH="$MOVED/bin:$PATH"
APP="$PWD/build/relocated/app"

if [ ! -d "$GEM_HOME/gems" ]; then
  echo "  installing rails (a few minutes)..."
  "$MOVED/bin/gem" install rails --no-document >/dev/null 2>&1 \
    && pass "rails gem installed using the relocated ruby" \
    || { fail "gem install rails failed"; exit 1; }
else
  pass "rails already installed"
fi

if [ ! -d "$APP" ]; then
  echo "  generating a minimal app..."
  "$GEM_HOME/bin/rails" new "$APP" --minimal --skip-git --skip-bundle >/dev/null 2>&1 \
    && pass "rails new succeeded" || fail "rails new failed"
fi

# --skip-bundle above means the app has no gems yet. Installing them here is not
# just setup: it proves native extensions still compile against a Ruby that has
# been moved, which is the thing a packaged app depends on.
if [ -d "$APP" ] && [ ! -f "$APP/Gemfile.lock" ]; then
  echo "  bundle install (compiles native extensions)..."
  ( cd "$APP" && "$MOVED/bin/bundle" install >/dev/null 2>&1 ) \
    && pass "native extensions compiled against the relocated ruby" \
    || fail "bundle install failed"
fi

if [ -d "$APP" ]; then
  ( cd "$APP"
    "$MOVED/bin/ruby" -e '
      ENV["RAILS_ENV"] = "production"
      ENV["SECRET_KEY_BASE_DUMMY"] = "1"
      require "./config/environment"
      require "rack/mock"
      Rails.application.routes.draw { get "/up", to: proc { [200, {"content-type"=>"text/plain"}, ["ok"]] } }
      status, = Rails.application.call(Rack::MockRequest.env_for("http://127.0.0.1/up"))
      abort "GET /up returned #{status}" unless status == 200
      puts "Rails #{Rails::VERSION::STRING} booted and served a request"
      puts "  psych   #{Psych::VERSION} (libyaml #{Psych::LIBYAML_VERSION})"
      puts "  openssl #{OpenSSL::OPENSSL_VERSION}"
    ' 2>&1 | tail -4
  ) && pass "Rails booted from the relocated interpreter" || fail "Rails did not boot"
fi

step "Payload size (what actually ships)"
printf "  interpreter  %s\n" "$(du -sh "$MOVED" | cut -f1)"
[ -d "$GEM_HOME" ] && printf "  app gems     %s\n" "$(du -sh "$GEM_HOME" | cut -f1)"
[ -d "$APP" ] && printf "  the app      %s\n" "$(du -sh "$APP" | cut -f1)"

step "Result"
[ "$FAIL" -eq 0 ] && printf '  \033[32mPASS\033[0m — this Ruby can ship inside an app bundle.\n' \
                  || printf '  \033[31mFAIL\033[0m — see the ✗ lines above.\n'
exit "$FAIL"
