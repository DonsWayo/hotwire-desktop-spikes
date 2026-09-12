# Spike 4 — does the architecture survive packaging?

Spikes 2 and 3 answered *can Ruby ship*. These answer the questions underneath
the design, each load-bearing, none previously measured.

```bash
./run.sh      # uses the relocatable interpreter spike 2 built
```

## Results, 12 September 2026, macOS arm64

| Check | Result |
|---|---|
| Rails boots from a **read-only** bundle with writable state redirected | **pass** |
| railties really does hardcode `tmp` creation under `Rails.root` | **confirmed** |
| Cold boot time | **not measured** — see below |

### Rails runs from a read-only bundle

A signed `.app` is read-only, while Rails expects `tmp`, `log` and `storage` to
be writable. Redirecting those to an OS data directory through
`config.paths` in an initializer works: the app booted and served a request with
its entire tree set `a-w`. This is the packaging shape a desktop app needs, and
it holds.

### `rails server` really is off limits

Confirmed by reading the installed gem, not by trusting the claim:
`railties .../commands/server/server_command.rb:70` does

```ruby
%w(cache pids sockets).each do |dir_to_make|
```

and creates them under `Rails.root` without consulting `config.paths`. In a
read-only bundle that is `Errno::EACCES`. Boot Puma from `config.ru` instead.

### Boot time is deliberately not reported

The check refuses to produce a number when the one-minute load average exceeds
half the core count, and prints `UNRELIABLE` instead. That is on purpose. The
feasibility study's own criticism of the existing literature was that every
published figure came from a loaded machine, and a number measured here would
have the same defect.

Observed under load 20 on 12 cores, for orientation only and not to be quoted:
fastest 1.66s, median 1.99s. That it stays near two seconds on a saturated
machine is encouraging, but **re-run this on an idle machine** before the number
means anything.

The bootsnap comparison is suppressed under the same condition, for the same
reason.

## Still unchecked

- **Turbo Streams over SSE with no ActionCable.** The transport the design
  chose, and untested. `turbo_stream_from` uses ActionCable by default, so the
  SSE path needs its own stream source.
- **Signing and notarization** of a bundle with an interpreter inside it, and
  whether Ruby's use of executable memory argues with the hardened runtime.
- **Payload pruning.** 180 MB is unpruned; docs, tests and unused stdlib are
  still in there.
- **Linux.** Not attempted on any axis.
