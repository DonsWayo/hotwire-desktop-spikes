# Spike 3 — the Windows gate

**Result: PASS**, 12 September 2026, on a free `windows-latest` runner.

The feasibility study called Windows the gate: it decides reach rather than
feasibility, and nobody had measured it. This answers it.

## What passed

| Check | Result |
|---|---|
| The portable RubyInstaller archive relocates and runs | pass |
| It survives a path containing a space (`C:\Program Files`-shaped) | pass |
| CI can build the whole bundle, with a devkit Ruby | pass |
| **The built bundle runs with no compiler anywhere on the machine** | **pass** |

The last row is the one that matters. The test copies the interpreter and the
CI-compiled gems somewhere else, renames `C:\msys64` and `C:\mingw64` out of
existence, strips `PATH` down to the interpreter plus Windows itself, and boots:

```
gcc on PATH: none — good
ruby    3.4.10 x64-mingw-ucrt at C:/shipped/ruby
psych   5.2.2 (libyaml 0.2.5)
openssl OpenSSL 3.6.3 9 Jun 2026
OK  Rails 8.1.3.1 booted and served a request
OK  runs with no compiler anywhere on the machine
```

## The finding underneath

Several gems ship **source-only** on Windows, with no `x64-mingw-ucrt` binary,
and must be compiled: `puma`, `io-console`, `nio4r`, `prism`, `json`,
`bigdecimal`, `erb`, `racc`, `rbs`.

That looked like a blocker and is not, because **an end user never installs
gems**. They double-click a bundle somebody else built. The compiler is a build
machine requirement, and the build machine already has one. This is how every
packaged Ruby application on Windows has ever worked.

One gem is worth calling out separately. `websocket-driver` also ships
source-only, and it arrives via `actioncable`. A single-user desktop app has no
cable server and rides Turbo Streams over SSE instead (spike 5), so it never
enters the payload at all.

The RubyInstaller FAQ warns that spaces in a path break gem installation. That
did not reproduce: a gem installed cleanly under
`C:\Program Files Test\Hotwire Desktop\`. The concern is dead, so a normal
install location is fine.

## Payload

| Part | Windows | macOS (spike 2) |
|---|---|---|
| Interpreter | 103 MB | 83 MB |
| App gems | 64 MB | 97 MB |

## Still unanswered

**Cold launch time with Defender enabled**, which is the other half of the
Windows question and the one the existing NativePHP report puts at three
minutes. A CI runner is not a representative machine for it, and neither is an
EC2 Windows Server instance, whose Defender and SmartScreen defaults differ from
consumer Windows 11. That measurement needs real hardware.

## A note on the iteration

Several runs in this spike's history failed on PowerShell path handling —
`.cmd` versus `.bat` binstubs, doubled backslashes, and hand-rolling an MSYS2
environment that RubyInstaller's `ridk` exists to configure. Those were
authoring mistakes, not findings, and none of them changed a conclusion. The
workflow now resolves binstubs rather than assuming them, and prints the
directory when it cannot, so the next failure explains itself.
