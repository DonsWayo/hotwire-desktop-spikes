# Spike 1 — can a webview hold a live connection to a loopback Puma?

The measurement that decides whether a Hotwire desktop framework is worth
building, and the one nobody appears to have published. If a page inside the
system webview cannot keep receiving pushed messages from a local Rails-shaped
server across display sleep, then every DOM update has to cross a process
boundary as a string, and "your existing Rails views, unchanged" stops being
true. That is a different, worse product.

Both transports run side by side against the same Puma, sharing one sequence
number, so a gap on one and not the other is immediately visible.

## Running it

```bash
./run.sh        # http://127.0.0.1:4321
```

Runtimes come from mise. `server.rb` refuses to start under any other
interpreter, because a harness that silently ran on a different Ruby would
produce numbers that mean nothing.

Open the page in a normal browser first as the control, then in each webview.

## Running it inside a real webview

`turbo-desktop.config.json` points the Turbo Desktop shell at this harness, so
the page runs in WKWebView rather than in Chrome:

```bash
cd ../../turbo_desktop
cp ../hotwire-desktop-spikes/spike01-loopback-streams/turbo-desktop.config.json .
cargo tauri dev
```

For Windows and Linux, run the same harness and open it in WebView2 and
WebKitGTK respectively. Three platforms is the point; one platform is an
anecdote.

## The protocol

Leave it running for an hour, and during that hour:

1. Sleep the display and wake it.
2. Minimise the window for ten minutes, then restore it.
3. Toggle Wi-Fi off and on.
4. Unplug Ethernet if there is any.
5. Let the machine idle until it sleeps on its own.

## Reading the result

`results.jsonl` is the record, and the server's own lines are the ground truth,
because a suspended page cannot report on itself:

- `connection.open` / `connection.close` with a reason, per transport
- `client.report` lines carrying what the page saw, including missed sequence
  numbers, gaps over three seconds, visibility changes and network changes

A healthy hour has two `connection.open` lines and no `connection.close` until
you stop it. Every close is a finding. Read the `reason` field: a client that
went away looks different from a write that failed.

## Stop condition

From the feasibility study: **stop the project if both the WebSocket and the
event stream fail on any one platform.** Relaying through the shell always works
technically, since it is just evaluating JavaScript, but if it becomes the only
path then the shell is load-bearing for every update and the value proposition
is gone.

One transport surviving is a pass. It tells you which one the framework should
default to, which is exactly what this is for.

## What this deliberately does not test

ActionCable. This uses a raw hijacked WebSocket so the webview's behaviour is
isolated from ActionCable's own reconnect logic and heartbeat. If the socket
dies here it would die there too, and this way a failure is unambiguous. Swap in
a real Rails app once the raw answer is known.
