# Spike 2 — a Ruby that can be moved, and boots Rails from the new place

**Result: PASS**, on macOS arm64, 12 September 2026.

## The question

A packaged desktop app has to carry its own interpreter. The obvious approach,
copying the Ruby you already have into the bundle, does not work: on macOS a
package-manager Ruby links absolute paths into `/opt/homebrew`, and not only
from Puma. `libruby` links gmp, `openssl.bundle` links libssl, and stdlib
`psych.bundle` links libyaml. **Rails cannot boot without psych**, so that last
one settles it on its own.

So the interpreter has to be built for the job. This spike tests whether that
actually works end to end.

## What was built

Ruby 3.4.8, configured with `--enable-load-relative` so it resolves its own
`lib/` and encodings relative to the binary rather than a compiled-in prefix,
linked against libyaml 0.2.5 and OpenSSL 3.5.4 built statically from source into
a local vendor prefix. `PKG_CONFIG_PATH` is cleared during configure so it
cannot wander back into Homebrew.

```bash
./build.sh     # ~40 min, OpenSSL is the long pole
./verify.sh
```

## What was verified

| Check | Result |
|---|---|
| No `/opt/homebrew` or `/usr/local` linkage in any binary or extension | pass |
| psych and openssl linked statically, no `.bundle` dependencies at all | pass |
| Runs after being copied to a different path and depth | pass |
| `RbConfig` prefix follows the binary | pass |
| psych loads and parses YAML | pass |
| OpenSSL works, zlib, json, fiddle, socket all load | pass |
| Native gems compile against the moved interpreter (sqlite3 2.9.6, rbs, debug) | pass |
| Rails 8.1.3.1 boots from the moved copy | pass |
| It serves an actual HTTP request | pass |

## Payload size

This is the number the packaging plan needed, and nobody had measured it.

| Part | Size |
|---|---|
| Interpreter | 83 MB |
| App gems (minimal Rails 8.1) | 97 MB |
| The app itself | 220 KB |
| **Total** | **~180 MB** |

Uncompressed, before any pruning of docs, test files or unused stdlib. For
comparison, an Electron shell alone is around 150 MB before your app.

## What this does not yet answer

- **Windows and Linux.** This is arm64 macOS only. Windows is the platform that
  decides reach, and it is untested.
- **Signing and notarization.** An interpreter inside a bundle has to be signed,
  and Ruby's use of executable memory may interact with the hardened runtime.
- **Boot time.** Not measured here. Roughly two seconds is the forgiveness
  threshold for an app icon.
- **Writable paths.** A `.app` is read-only while Rails expects `tmp`, `log` and
  `storage` to be writable, so a packaged app needs an OS data directory.
- **`rails server` is still off limits.** Railties hardcodes creating `tmp/cache`,
  `tmp/pids` and `tmp/sockets` under `Rails.root` regardless of `config.paths`.
  Boot Puma from `config.ru` instead.

## Note on runtimes

The Ruby produced here is a redistributable artifact, not a development runtime.
Development runtimes come from mise, always.
