#!/bin/bash
# Spike 2: build a CRuby that can be moved, and boot Rails from the new location.
#
# The finding this exists to test: a package-manager Ruby cannot be shipped. On
# macOS, libruby links gmp, stdlib psych links libyaml, and openssl/puma link
# libssl — all by absolute /opt/homebrew path. Rails will not boot without psych,
# so copying an existing Ruby into an app bundle fails on any path.
#
# So the interpreter has to be built for this: --enable-load-relative makes it
# resolve its own lib/ and encodings relative to the binary, and the libraries it
# needs are linked statically from sources we vendor ourselves.
#
# This is NOT a development runtime. Dev runtimes come from mise, always. This
# builds a redistributable artifact that ships inside a .app.

set -euo pipefail
cd "$(dirname "$0")"

RUBY_VERSION="${RUBY_VERSION:-3.4.8}"
OPENSSL_VERSION="${OPENSSL_VERSION:-3.5.4}"
YAML_VERSION="${YAML_VERSION:-0.2.5}"

WORK="$PWD/build"
SRC="$WORK/src"
VENDOR="$WORK/vendor"
PREFIX="$WORK/out/ruby"
JOBS="$(sysctl -n hw.ncpu)"
LOG="$WORK/build.log"

mkdir -p "$SRC" "$VENDOR" "$WORK/out"
exec > >(tee -a "$LOG") 2>&1

step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
have() { [ -f "$1" ]; }

free_gb=$(df -g "$PWD" | tail -1 | awk '{print $4}')
step "Free disk: ${free_gb}G (need ~3G)"
[ "$free_gb" -lt 3 ] && { echo "Not enough disk. Free some space first."; exit 1; }

fetch() { # url sha-optional
  local url="$1" file="$SRC/$(basename "$1")"
  have "$file" || curl -fsSL --retry 3 -o "$file" "$url"
  echo "$file"
}

# ---------------------------------------------------------------- libyaml
if have "$VENDOR/lib/libyaml.a"; then
  step "libyaml $YAML_VERSION already built"
else
  step "Building libyaml $YAML_VERSION (static)"
  tar -xzf "$(fetch "https://github.com/yaml/libyaml/releases/download/$YAML_VERSION/yaml-$YAML_VERSION.tar.gz")" -C "$SRC"
  ( cd "$SRC/yaml-$YAML_VERSION"
    ./configure --prefix="$VENDOR" --enable-static --disable-shared
    make -j"$JOBS" && make install )
fi

# ---------------------------------------------------------------- openssl
if have "$VENDOR/lib/libssl.a"; then
  step "OpenSSL $OPENSSL_VERSION already built"
else
  step "Building OpenSSL $OPENSSL_VERSION (static, no-shared) — the long pole, ~20 min"
  tar -xzf "$(fetch "https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VERSION/openssl-$OPENSSL_VERSION.tar.gz")" -C "$SRC"
  ( cd "$SRC/openssl-$OPENSSL_VERSION"
    ./Configure darwin64-arm64-cc no-shared no-tests no-docs --prefix="$VENDOR" --openssldir="$VENDOR/ssl"
    make -j"$JOBS" && make install_sw )
fi

# ---------------------------------------------------------------- ruby
if have "$PREFIX/bin/ruby"; then
  step "Ruby $RUBY_VERSION already built at $PREFIX"
else
  step "Building Ruby $RUBY_VERSION with --enable-load-relative"
  tar -xzf "$(fetch "https://cache.ruby-lang.org/pub/ruby/${RUBY_VERSION%.*}/ruby-$RUBY_VERSION.tar.gz")" -C "$SRC"
  ( cd "$SRC/ruby-$RUBY_VERSION"
    # PKG_CONFIG_PATH is cleared so configure cannot wander into /opt/homebrew.
    env -u PKG_CONFIG_PATH \
    ./configure \
      --prefix="$PREFIX" \
      --enable-load-relative \
      --disable-install-doc \
      --with-openssl-dir="$VENDOR" \
      --with-libyaml-dir="$VENDOR" \
      --without-gmp \
      --enable-shared=no
    make -j"$JOBS" && make install )
fi

step "Built: $("$PREFIX/bin/ruby" -v)"
echo "Next: ./verify.sh"
