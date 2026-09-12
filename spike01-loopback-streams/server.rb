# frozen_string_literal: true
#
# Spike 1: can a webview hold a live server-push connection to a loopback Puma?
#
# The question this answers, which nobody appears to have published an answer to:
# does a page inside WKWebView / WebView2 / WebKitGTK keep receiving pushed
# messages from a Rails-shaped server on 127.0.0.1 across display sleep, window
# backgrounding and a network interface toggle — and does SSE or a WebSocket
# survive better?
#
# Both transports run side by side so they can be compared under identical
# conditions. The server is the ground truth: it records when each connection
# opened and closed, because a page that has been suspended cannot report on
# itself.
#
# Run:  ./run.sh          (or: mise exec ruby@3.4.8 -- ruby server.rb)

# Runtimes are managed by mise, never Homebrew or the system. A harness that
# silently ran under a different interpreter would produce results that mean
# nothing, so this refuses rather than guesses.
unless RbConfig.ruby.include?("/mise/")
  abort <<~MSG
    This must run under the mise-managed Ruby, but it was started with:
      #{RbConfig.ruby}

    Use:  ./run.sh
      or: mise exec ruby@3.4.8 -- ruby server.rb
  MSG
end

require "json"
require "socket"
require "time"
require "securerandom"
require "websocket/driver"

PORT      = Integer(ENV.fetch("PORT", "4321"))
INTERVAL  = Float(ENV.fetch("INTERVAL", "1.0"))   # seconds between pushes
RESULTS   = File.expand_path("results.jsonl", __dir__)

def record(event)
  line = event.merge(at: Time.now.utc.iso8601(3), monotonic: Process.clock_gettime(Process::CLOCK_MONOTONIC).round(3))
  File.open(RESULTS, "a") { |f| f.puts(JSON.generate(line)) }
  warn "[#{line[:at]}] #{line[:event]} #{line.reject { |k, _| %i[at monotonic event].include?(k) }.to_json}"
end

# --- the broadcast hub -------------------------------------------------------
# One sequence number shared by both transports, so a gap on one and not the
# other is immediately visible in the numbers.

class Hub
  def initialize
    @mutex  = Mutex.new
    @queues = {}
    @seq    = 0
  end

  def subscribe(kind)
    q = Queue.new
    id = SecureRandom.hex(4)
    @mutex.synchronize { @queues[id] = { queue: q, kind: kind } }
    record(event: "connection.open", transport: kind, connection: id, open_now: count)
    [id, q]
  end

  def unsubscribe(id, reason)
    entry = @mutex.synchronize { @queues.delete(id) }
    return unless entry

    record(event: "connection.close", transport: entry[:kind], connection: id,
           reason: reason, open_now: count)
  end

  def count = @mutex.synchronize { @queues.size }

  def run
    Thread.new do
      loop do
        sleep INTERVAL
        @mutex.synchronize do
          @seq += 1
          payload = { seq: @seq, sent_at: Time.now.utc.iso8601(3) }
          @queues.each_value { |e| e[:queue].push(payload) }
        end
      end
    end
  end
end

HUB = Hub.new
HUB.run

# --- SSE ---------------------------------------------------------------------
# Deliberately shaped like a Turbo Stream: the `text/vnd.turbo-stream.html`
# fragment is what a real <turbo-stream-source> would receive, so this measures
# the thing the framework would actually do, not a toy ping.

def turbo_stream_fragment(payload)
  %(<turbo-stream action="update" target="seq"><template>#{payload[:seq]}</template></turbo-stream>)
end

class SSEStream
  def initialize(id, queue) = (@id, @queue = id, queue)

  def each
    yield "retry: 2000\n\n"
    loop do
      payload = @queue.pop
      yield "event: message\ndata: #{JSON.generate(payload.merge(html: turbo_stream_fragment(payload)))}\n\n"
    end
  rescue StandardError => e
    HUB.unsubscribe(@id, "write failed: #{e.class}")
    raise
  ensure
    HUB.unsubscribe(@id, "stream ended")
  end

  def close = HUB.unsubscribe(@id, "closed by server")
end

# --- WebSocket ---------------------------------------------------------------
# Raw hijack rather than ActionCable, to isolate the webview's behaviour from
# ActionCable's own reconnect logic. If the socket dies here, it would die there.

class SocketWriter
  def initialize(io) = @io = io
  def write(data) = @io.write(data)
  def close = @io.close rescue nil
end

def handle_websocket(env)
  env["rack.hijack"].call
  io     = env["rack.hijack_io"]
  writer = SocketWriter.new(io)
  driver = WebSocket::Driver.server(writer)

  id, queue = HUB.subscribe("websocket")
  driver.on(:connect) { driver.start if WebSocket::Driver.websocket?(env) }
  driver.on(:close)   { HUB.unsubscribe(id, "client closed"); io.close rescue nil }

  # Replay the handshake bytes Rack already consumed into the driver.
  driver.parse("#{env['rack.request.method'] || 'GET'} #{env['PATH_INFO']} HTTP/1.1\r\n")
  env.each do |key, value|
    next unless key.start_with?("HTTP_")

    header = key.sub("HTTP_", "").split("_").map(&:capitalize).join("-")
    driver.parse("#{header}: #{value}\r\n")
  end
  driver.parse("\r\n")

  Thread.new do
    loop do
      payload = queue.pop
      driver.text(JSON.generate(payload.merge(html: turbo_stream_fragment(payload))))
    end
  rescue StandardError => e
    HUB.unsubscribe(id, "write failed: #{e.class}")
    io.close rescue nil
  end

  Thread.new do
    loop { driver.parse(io.readpartial(4096)) }
  rescue StandardError
    HUB.unsubscribe(id, "socket read ended")
    io.close rescue nil
  end

  [-1, {}, []]
end

PAGE = File.read(File.expand_path("index.html", __dir__))

APP = lambda do |env|
  case env["PATH_INFO"]
  when "/"
    [200, { "content-type" => "text/html; charset=utf-8", "cache-control" => "no-store" }, [PAGE]]
  when "/stream"
    id, queue = HUB.subscribe("sse")
    [200, { "content-type" => "text/event-stream", "cache-control" => "no-cache",
            "connection" => "keep-alive", "x-accel-buffering" => "no" }, SSEStream.new(id, queue)]
  when "/ws"
    handle_websocket(env)
  when "/report"
    body = env["rack.input"].read
    record(JSON.parse(body, symbolize_names: true).merge(event: "client.report"))
    [204, {}, []]
  when "/results"
    [200, { "content-type" => "text/plain" }, [File.exist?(RESULTS) ? File.read(RESULTS) : ""]]
  when "/turbo-desktop/path-configuration.json"
    # So the turbo_desktop shell recognises this as its own app.
    [200, { "content-type" => "application/json" }, [JSON.generate(rules: [])]]
  else
    [404, { "content-type" => "text/plain" }, ["not found"]]
  end
end

record(event: "server.start", port: PORT, interval: INTERVAL, ruby: RUBY_VERSION)
warn "\n  Spike 1 harness on http://127.0.0.1:#{PORT}\n  Results: #{RESULTS}\n\n"

require "puma"
require "puma/configuration"
require "puma/launcher"

config = Puma::Configuration.new do |c|
  c.bind "tcp://127.0.0.1:#{PORT}"
  c.threads 4, 32
  c.workers 0
  c.app APP
  c.enable_keep_alives true
end
Puma::Launcher.new(config).run
