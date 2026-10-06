# Hotwire desktop spikes

The question this repository exists to answer: **can a Hotwire/Turbo Rails app
ship as a native desktop app, and what breaks?** Not "can it be demonstrated" —
it has been demonstrated many times. The question is whether your existing Rails
views keep working unchanged once a webview, a bundled interpreter and an app
bundle sit between them and the user.

Each directory is one spike. Each states its own question, its own protocol, its
own stop condition, and what it did or did not prove. Where a spike has not been
run, its README says so.

**Status: spikes in progress.** A consolidated write-up is planned. It does not
exist yet, so nothing is linked to it here; the per-spike READMEs are the
record until it lands.

## The spikes

| # | Spike | Question | Verdict | Status |
|---|---|---|---|---|
| 1 | [loopback streams](spike01-loopback-streams/README.md) | Can a webview hold a live WebSocket and SSE connection to a loopback Puma across display sleep, backgrounding and a network change? | **Not recorded — not run.** The harness is built; the measurement still needs a human to sleep a display | Harness done, measurement outstanding |
| 2 | [relocatable Ruby](spike02-relocatable-ruby/README.md) | Can a Ruby that is moved to an arbitrary path boot Rails from the new place? | **PASS**, macOS arm64, 12 September 2026 | Done |
| 3 | [the Windows gate](spike03-windows-ruby/README.md) | Can a Windows bundle be built in CI and run on a machine with no compiler on it? | **PASS**, free `windows-latest` runner, 12 September 2026 | Done; runs on push and on demand |
| 4 | [packaging checks](spike04-packaging-checks/README.md) | Does the architecture survive a read-only signed bundle? | **Partial pass**, macOS arm64, 12 September 2026 — Rails boots read-only; boot time deliberately **not measured** | Done except boot time, which is unmeasured on purpose |
| 5 | [Turbo Streams over SSE](spike05-turbo-sse/README.md) | Can Turbo be driven by an `EventSource` instead of ActionCable, with no adapter? | **PASS** in Chromium and WebKit, macOS and Linux, 12 September 2026 | Done |
| 6 | [macOS signing](spike06-macos-signing/README.md) | Does the hardened runtime block a bundle containing an interpreter? | **Pass with two entitlements**, ad-hoc signed, macOS arm64, 15 September 2026 — and the README is explicit that this is an upper bound, not a recommendation | Matrix done; notarization and a real Developer ID outstanding |

There is no top-level notes or docs file. The per-spike READMEs are the whole
record.

## What we learned so far

Only conclusions the spikes actually support:

- **A package-manager Ruby cannot be shipped.** On macOS it links absolute
  `/opt/homebrew` paths, and stdlib `psych` links libyaml — so Rails cannot boot
  at all. The interpreter has to be built for the job (`--enable-load-relative`).
  Spike 2.
- **The Windows gate is not a gate.** Several gems ship source-only on Windows
  and must be compiled — but only on the build machine. An end user never
  installs gems. A CI-built bundle boots Rails with `C:\msys64` and `C:\mingw64`
  renamed away. Spike 3.
- **The spaces-in-paths concern did not reproduce.** A gem installed cleanly
  under `C:\Program Files Test\Hotwire Desktop\`. Spike 3.
- **Turbo's stream source interface is not ActionCable-specific.** An
  `EventSource` satisfies `connectStreamSource` directly, so an SSE transport
  needs no shim. Proven by asserting the DOM changed in real engines, not by
  reading the source. Spike 5.
- **Rails runs from a read-only bundle** once `tmp`, `log` and `storage` are
  redirected through `config.paths`. Confirmed against the installed railties
  source, not by trusting the claim. Spike 4.
- **`rails server` is off limits in a bundle.** Railties hardcodes creating
  `tmp/cache`, `tmp/pids` and `tmp/sockets` under `Rails.root`, which is
  `Errno::EACCES` on a read-only tree. Boot Puma from `config.ru`. Spikes 2 and
  4.
- **macOS signing needs entitlements, and they go on the interpreter.** Not on
  the bundle: the main executable is a launcher script, and `ruby` is what
  `dlopen`s the extensions. Both `disable-library-validation` and
  `allow-unsigned-executable-memory` were needed under ad-hoc signing, and they
  fail in different ways. Spike 6.
- **Payload is roughly 180 MB unpruned** on macOS — 83 MB interpreter, 97 MB
  minimal Rails 8.1 gems — against around 150 MB for an Electron shell alone.
  Spike 2. Spike 6 measured 186 MB for the built `.app`.

Not learned, and not assumed anywhere: whether a webview actually survives
display sleep (spike 1 is the whole reason this repository exists), cold launch
time on Windows with Defender enabled, or whether Linux works on any axis.

## Reproducing

Each command is taken from that spike's own README. There is no top-level test
suite and no linter in this repository.

```bash
# Spike 1 — harness on http://127.0.0.1:4321
cd spike01-loopback-streams && ./run.sh
./soak.sh     # one hour, needs a human to sleep the display
./report.sh   # turn results.jsonl into a verdict

# Spike 2 — ~40 min, OpenSSL is the long pole
cd spike02-relocatable-ruby && ./build.sh && ./verify.sh

# Spike 3 — CI only, on a free public runner
#   .github/workflows/spike03-windows-ruby.yml

# Spike 4 — uses the relocatable interpreter spike 2 built
cd spike04-packaging-checks && ./run.sh

# Spike 5 — starts the server, drives both engines, reports, stops
cd spike05-turbo-sse && ./test.sh
./run.sh      # just the server

# Spike 6 — builds the bundle four ways and runs each
cd spike06-macos-signing && ./verify.sh
```

Spike 3 and spike 5 also run in CI, on `windows-latest` and `ubuntu-latest`
respectively. Development runtimes come from mise; the interpreters spikes 2, 4
and 6 exercise are shipped artifacts, and spike 2's README is clear that they
are not development runtimes.

## Status

- **Complete with a recorded verdict:** 2, 3, 5.
- **Complete but deliberately partial:** 4 — the architecture checks pass, the
  boot-time number is refused on a loaded machine rather than reported.
- **Complete as an experiment, incomplete as a release answer:** 6 — the
  entitlement matrix is done under ad-hoc signing; notarization, Gatekeeper on
  first launch and whether a real Developer ID removes the library-validation
  entitlement are all open.
- **Built, not yet run:** 1. Every other spike depends on its answer.
- **No stub directories.** All six contain code. There is no seventh spike on
  disk; the "7 topics" are GitHub topic labels, not directories.

Each spike's README lists its own "still open" items, and those lists are
authoritative. This README does not attempt to resolve them.