#!/bin/bash
# Assemble a real .app around a relocatable Ruby, then sign it.
#
# The open question this exists for: macOS's hardened runtime blocks unsigned
# executable memory and unsigned dynamic libraries. Ruby loads every C extension
# with dlopen, so the question is whether a signed bundle containing an
# interpreter still runs, and which entitlements it needs to.
#
# Ad-hoc signing (`--sign -`) reproduces the hardened runtime's restrictions
# without an Apple Developer certificate, so this answers the question for free.
# Notarization proper still needs a real identity.

set -euo pipefail
cd "$(dirname "$0")"

RUBY_SRC="${RUBY_SRC:-$PWD/../spike02-relocatable-ruby/build/out/ruby}"
GEMS_SRC="${GEMS_SRC:-$PWD/../spike02-relocatable-ruby/build/relocated/gems}"
APP_SRC="${APP_SRC:-$PWD/../spike02-relocatable-ruby/build/relocated/app}"
OUT="$PWD/build"
APP="$OUT/Spike.app"
IDENTITY="${IDENTITY:--}"          # "-" is ad-hoc
ENTITLEMENTS="${ENTITLEMENTS:-}"   # optional plist path

[ -x "$RUBY_SRC/bin/ruby" ] || { echo "No interpreter at $RUBY_SRC — run spike 2 first."; exit 1; }

rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp -R "$RUBY_SRC" "$APP/Contents/Resources/ruby"
[ -d "$GEMS_SRC" ] && cp -R "$GEMS_SRC" "$APP/Contents/Resources/gems"
[ -d "$APP_SRC" ]  && cp -R "$APP_SRC"  "$APP/Contents/Resources/app"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Spike</string>
  <key>CFBundleIdentifier</key><string>dev.hotwiredesktop.spike</string>
  <key>CFBundleExecutable</key><string>spike</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
</dict>
</plist>
PLIST

cat > "$APP/Contents/MacOS/spike" <<'LAUNCH'
#!/bin/bash
# The launcher a packaged app would use: resolve the interpreter beside itself,
# keep everything writable outside the read-only bundle, never call rails server.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export GEM_HOME="$here/Resources/gems"
export GEM_PATH="$GEM_HOME:$here/Resources/ruby/lib/ruby/gems/3.4.0"
export DESKTOP_DATA_DIR="${DESKTOP_DATA_DIR:-$HOME/Library/Application Support/dev.hotwiredesktop.spike}"
mkdir -p "$DESKTOP_DATA_DIR"/{tmp,log,storage}
export RAILS_ENV=production SECRET_KEY_BASE_DUMMY=1
cd "$here/Resources/app"
exec "$here/Resources/ruby/bin/ruby" "$@"
LAUNCH
chmod +x "$APP/Contents/MacOS/spike"

# Inside-out signing: every nested binary before the bundle that contains it.
# --deep is deprecated and signs in the wrong order, so it is not used.
echo "==> signing nested binaries (identity: $IDENTITY)"
sign_args=(--force --timestamp=none --options runtime --sign "$IDENTITY")
[ -n "$ENTITLEMENTS" ] && sign_args+=(--entitlements "$ENTITLEMENTS")

count=0
while IFS= read -r -d '' f; do
  codesign "${sign_args[@]}" "$f" 2>/dev/null && count=$((count + 1)) || echo "    could not sign: ${f#$APP/}"
done < <(find "$APP/Contents/Resources" \( -name '*.dylib' -o -name '*.bundle' -o -name '*.so' \) -type f -print0)
echo "    signed $count nested binaries"

codesign "${sign_args[@]}" "$APP/Contents/Resources/ruby/bin/ruby"
codesign "${sign_args[@]}" "$APP"

echo "==> $APP"
