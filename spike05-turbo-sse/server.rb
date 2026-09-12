# frozen_string_literal: true
#
# Spike 5: do Turbo Streams work over SSE with no ActionCable?
#
# This is the transport the whole design rests on. Turbo's own
# <turbo-cable-stream-source> is an ActionCable client, and actioncable pulls in
# websocket-driver, which ships no x64-mingw-ucrt binary (spike 3). So the
# desktop design says: broadcast over SSE instead.
#
# Reading turbo.js, StreamObserver#connectStreamSource does exactly one thing:
#   source.addEventListener("message", this.receiveMessageEvent, false)
# An EventSource satisfies that. This proves it end to end, in a browser, with
# the real Turbo build and real turbo-stream fragments.
#
# Run: ./run.sh   (then ./test.sh drives a real browser against it)

# Locally, dev runtimes come from mise, always. CI supplies its own Ruby, so the
# guard applies only where a wrong interpreter is actually possible.
if !ENV["CI"] && !RbConfig.ruby.include?("/mise/")
  abort "Run through ./run.sh — dev runtimes come from mise."
end

require "json"
require "securerandom"

PORT     = Integer(ENV.fetch("PORT", "4322"))
INTERVAL = Float(ENV.fetch("INTERVAL", "0.4"))
ROOT     = __dir__

class Hub
  def initialize = (@m = Mutex.new; @subs = {}; @seq = 0)

  def subscribe
    q = Queue.new
    id = SecureRandom.hex(4)
    @m.synchronize { @subs[id] = q }
    [id, q]
  end

  def unsubscribe(id) = @m.synchronize { @subs.delete(id) }
  def count = @m.synchronize { @subs.size }

  def run
    Thread.new do
      loop do
        sleep INTERVAL
        @m.synchronize do
          @seq += 1
          @subs.each_value { |q| q.push(@seq) }
        end
      end
    end
  end
end

HUB = Hub.new
HUB.run

# Real turbo-stream fragments, deliberately multi-line and indented the way
# Rails renders a turbo_stream template. SSE has no notion of a multi-line
# payload, so each line needs its own `data:` field; the browser rejoins them
# with "\n". Getting this wrong is the most likely way an SSE bridge silently
# delivers nothing, so it is tested rather than flattened.
def fragment(seq)
  <<~HTML
    <turbo-stream action="append" target="feed">
      <template>
        <li class="row" data-seq="#{seq}">message #{seq}</li>
      </template>
    </turbo-stream>
    <turbo-stream action="update" target="counter">
      <template>#{seq}</template>
    </turbo-stream>
  HTML
end

def sse_event(payload)
  lines = payload.split("\n").map { |l| "data: #{l}" }.join("\n")
  "#{lines}\n\n"
end

class Stream
  def initialize(id, queue) = (@id, @queue = id, queue)

  def each
    yield "retry: 1000\n\n"
    loop do
      seq = @queue.pop
      yield sse_event(fragment(seq))
    end
  rescue StandardError
    raise
  ensure
    HUB.unsubscribe(@id)
  end
end

def file(name, type)
  [200, { "content-type" => type, "cache-control" => "no-store" }, [File.read(File.join(ROOT, name))]]
end

APP = lambda do |env|
  case env["PATH_INFO"]
  when "/"            then file("index.html", "text/html; charset=utf-8")
  when "/turbo.js"    then file("vendor/turbo.js", "text/javascript; charset=utf-8")
  when "/stream"
    id, q = HUB.subscribe
    [200, { "content-type" => "text/event-stream", "cache-control" => "no-cache",
            "connection" => "keep-alive", "x-accel-buffering" => "no" }, Stream.new(id, q)]
  else [404, { "content-type" => "text/plain" }, ["not found"]]
  end
end

warn "  Spike 5 on http://127.0.0.1:#{PORT}  (turbo #{File.read(File.join(ROOT, 'vendor/TURBO_VERSION')).strip})"

require "puma"
require "puma/configuration"
require "puma/launcher"
Puma::Launcher.new(Puma::Configuration.new { |c|
  c.bind "tcp://127.0.0.1:#{PORT}"
  c.threads 2, 16
  c.workers 0
  c.app APP
  c.log_requests false
}).run
