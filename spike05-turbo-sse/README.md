# Spike 5 — Turbo Streams over SSE, with no ActionCable

**Result: PASS** in Chromium and WebKit, 12 September 2026.

## Why this is the load-bearing check

The desktop design chose Server-Sent Events over ActionCable for two independent
reasons: WebSockets inside a webview are untested by anyone, and `actioncable`
pulls in `websocket-driver`, which ships no `x64-mingw-ucrt` binary and so
forces a compiler onto the Windows build (spike 3).

But Turbo's own `<turbo-cable-stream-source>` *is* an ActionCable client. So the
whole architecture rested on an assumption nobody had tested: that Turbo can be
driven by something else.

## What the source says

`StreamObserver#connectStreamSource` in turbo 8.0.23 does exactly one thing:

```js
connectStreamSource(source) {
  if (!this.streamSourceIsConnected(source)) {
    this.sources.add(source);
    source.addEventListener("message", this.receiveMessageEvent, false);
  }
}
```

An `EventSource` satisfies that interface. No adapter, no shim: an EventSource
*is* a valid stream source. The entire bridge is this custom element.

```js
class TurboSSEStreamSource extends HTMLElement {
  connectedCallback() {
    this.source = new EventSource(this.getAttribute("src"));
    Turbo.connectStreamSource(this.source);
  }
  disconnectedCallback() {
    Turbo.disconnectStreamSource(this.source);
    this.source?.close();
  }
}
```

## What was actually proven

Reading the source is not evidence that it works, so this drives real browser
engines at a real Puma and asserts the **DOM changed**, not that a message
arrived.

| Engine | Result |
|---|---|
| Chromium (WebView2's engine) | rows appended, counter updated, sequence contiguous |
| WebKit (WKWebView's engine) | rows appended, counter updated, sequence contiguous |

Both `append` and `update` actions were exercised, so replacement is covered as
well as accumulation.

### The multi-line trap

SSE has no concept of a multi-line payload: every line of the body needs its own
`data:` field, and the browser rejoins them with `\n`. A `turbo_stream` template
renders indented and multi-line. Flatten it wrong and the browser silently
delivers nothing, which is the most likely way an SSE bridge appears to work and
does not.

The fragments here are deliberately multi-line and indented the way Rails
renders them, so that framing is under test rather than avoided.

## Running it

```bash
./test.sh          # starts the server, drives both engines, reports, stops
./run.sh           # just the server, to look at the page yourself
```

## What this does not prove

- **Survival.** This shows the transport works, not that it holds across display
  sleep, backgrounding or a network change. That is spike 1, still unrun.
- **Reconnection semantics.** `EventSource` reconnects on its own and reports a
  `Last-Event-ID`, but nothing here replays missed messages. A real
  implementation needs to decide what happens to a broadcast sent while the page
  was away.
- **Rails-side rendering.** The fragments here are handwritten. Wiring
  `turbo_stream.append` through a real broadcast path is a separate step.
