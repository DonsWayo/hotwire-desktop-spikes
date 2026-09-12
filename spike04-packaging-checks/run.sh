#!/bin/bash
# Uses the relocatable interpreter spike 2 built. Dev runtimes come from mise;
# this deliberately runs the *shipped* artifact, which is the thing under test.
set -euo pipefail
cd "$(dirname "$0")"

S2="$PWD/../spike02-relocatable-ruby/build/relocated"
[ -x "$S2/ruby/bin/ruby" ] || { echo "Run ../spike02-relocatable-ruby/build.sh and verify.sh first."; exit 1; }
[ -d "$S2/app" ]           || { echo "spike 2 has no generated app; run its verify.sh."; exit 1; }

export RUBY_BIN="$S2/ruby/bin/ruby"
export APP_PATH="$S2/app"
export GEM_HOME="$S2/gems"
export GEM_PATH="$S2/gems:$S2/ruby/lib/ruby/gems/3.4.0"

exec "$RUBY_BIN" checks.rb "$@"
