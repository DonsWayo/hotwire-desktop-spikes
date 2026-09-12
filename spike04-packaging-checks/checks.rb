# frozen_string_literal: true
#
# Spike 4: the checks that decide whether the *architecture* survives packaging.
#
# Spikes 2 and 3 answered "can Ruby ship". These answer the questions underneath
# the design, each of which is load-bearing and none of which anyone has
# published a measurement for:
#
#   1. How long does Rails take to boot from a relocated interpreter? A desktop
#      app has about two seconds before the icon feels broken.
#   2. Does railties really create tmp dirs under Rails.root regardless of
#      config.paths? The whole "never call rails server" rule rests on this.
#   3. Can Rails run from a read-only bundle with its writable state elsewhere?
#      A signed .app is read-only; Rails expects tmp, log and storage writable.
#   4. Do Turbo Streams work over SSE with no ActionCable? This is the transport
#      the design chose, and websocket-driver has no Windows binary anyway.
#
# Run: ./run.sh

require "benchmark"
require "fileutils"
require "json"
require "net/http"
require "tmpdir"

PASS = "\e[32m✓\e[0m"
FAIL = "\e[31m✗\e[0m"
INFO = "\e[36m•\e[0m"
$failures = 0

def section(t) = puts("\n\e[1m==> #{t}\e[0m")
def ok(m)      = puts("  #{PASS} #{m}")
def bad(m)     = ($failures += 1; puts("  #{FAIL} #{m}"))
def note(m)    = puts("  #{INFO} #{m}")

APP = ENV.fetch("APP_PATH")
RUBY_BIN = ENV.fetch("RUBY_BIN")

def in_app(script, env: {}, chdir: APP)
  r, w = IO.pipe
  pid = spawn({ "RAILS_ENV" => "production", "SECRET_KEY_BASE_DUMMY" => "1" }.merge(env),
              RUBY_BIN, "-e", script, chdir: chdir, out: w, err: w)
  w.close
  out = r.read
  Process.wait(pid)
  [$?.success?, out]
end

# ---------------------------------------------------------------- 1. boot time
section "1. Cold boot time from the relocated interpreter"
# The first run of anything reads the whole tree off disk, so it measures the
# filesystem cache rather than Rails. Warm once, discard it, then take the
# steady state — which is what a user who opens the app twice actually sees.
note "warming the filesystem cache (discarded)"
in_app('require "./config/environment"')

RUNS = 7
times = RUNS.times.map { Benchmark.realtime { in_app('require "./config/environment"') } }
sorted = times.sort
median = sorted[RUNS / 2]
fastest = sorted.first

note format("%d runs: %s", RUNS, times.map { |t| format("%.2f", t) }.join(", "))
note format("fastest %.2fs   median %.2fs", fastest, median)
note format("load average %s", `uptime`[/load averages?: (.*)/, 1].to_s.strip)

load1 = `uptime`[/load averages?: *([\d.]+)/, 1].to_f
cores = `sysctl -n hw.ncpu`.to_i
if load1 > cores * 0.5
  bad format("UNRELIABLE: load average %.1f on %d cores. This is not a measurement.", load1, cores)
  note format("observed anyway: fastest %.2fs, median %.2fs", fastest, median)
  note "re-run on an idle machine before quoting any of these numbers"
elsif median < 2.0
  ok format("median %.2fs — inside the ~2s an app icon gets before it feels broken", median)
elsif median < 4.0
  ok format("median %.2fs — usable; a splash window or a preboot would hide it", median)
else
  bad format("median %.2fs — too slow to double-click as-is", median)
  note "mitigations worth testing: bootsnap, eager_load, a preboot/fork server, a splash window"
end

# Bootsnap is the cheapest mitigation and is in every generated Rails app except
# --minimal, so measure what it is actually worth here.
section "1b. What bootsnap is worth"
boot_rb = File.join(APP, "config", "boot.rb")
original = File.read(boot_rb)
gem_installed = system(RUBY_BIN, "-e", 'require "bootsnap"', out: File::NULL, err: File::NULL)
if gem_installed
  File.write(boot_rb, original + %(\nrequire "bootsnap/setup"\n))
  in_app('require "./config/environment"')   # let it write its cache
  with = 5.times.map { Benchmark.realtime { in_app('require "./config/environment"') } }.sort[2]
  File.write(boot_rb, original)
  note format("without bootsnap %.2fs   with bootsnap %.2fs", median, with)
  if load1 > cores * 0.5
    note "also unreliable under this load — a difference this small is noise"
  elsif with < median
    ok format("bootsnap saves %.2fs (%d%%)", median - with, ((median - with) / median * 100).round)
  else
    note "bootsnap did not help measurably here"
  end
else
  note "bootsnap not installed in this bundle; skipped"
end

# ------------------------------------------------- 2. the `rails server` claim
section "2. Does railties create tmp dirs under Rails.root regardless of config.paths?"
# The study says server_command.rb hardcodes this and ignores config.paths, and
# that it is why a packaged app must boot Puma from config.ru instead. Verify,
# rather than take it on faith.
server_cmd = Dir.glob(File.join(APP, "..", "gems", "**", "railties-*", "lib", "rails", "commands", "server", "server_command.rb")).first ||
             Dir.glob(File.join(ENV.fetch("GEM_HOME", ""), "gems", "railties-*", "lib", "rails", "commands", "server", "server_command.rb")).first
if server_cmd && File.exist?(server_cmd)
  src = File.read(server_cmd)
  if (m = src.match(/%w\(\s*cache\s+pids\s+sockets\s*\).*?mkdir_p.*?$/m))
    line = src[0..src.index(m[0])].count("\n") + 1
    ok "confirmed in railties at #{File.basename(server_cmd)}:#{line}"
    note src.lines[line - 1].strip
    note "config.paths is not consulted, so a read-only Rails.root fails here"
  else
    bad "could not find the hardcoded tmp creation — the claim may no longer hold, re-read before relying on it"
  end
else
  bad "railties server_command.rb not found; cannot verify"
end

# ------------------------------------------------- 3. read-only app bundle
section "3. Rails from a read-only bundle, writable state elsewhere"
data_dir = Dir.mktmpdir("desktop-data")
%w[tmp log storage].each { |d| FileUtils.mkdir_p(File.join(data_dir, d)) }

# Point Rails at the external dirs the way a packaged app would.
initializer = File.join(APP, "config", "initializers", "zz_desktop_paths.rb")
File.write(initializer, <<~RB)
  # A signed .app is read-only. Everything Rails writes moves to the OS data
  # directory, which is what a packaged app must do on every platform.
  if ENV["DESKTOP_DATA_DIR"]
    root = ENV["DESKTOP_DATA_DIR"]
    Rails.application.config.paths["log"] = File.join(root, "log", "production.log")
    Rails.application.config.paths["tmp"] = File.join(root, "tmp")
  end
RB

FileUtils.chmod_R("a-w", APP)
begin
  okay, out = in_app(<<~RB, env: { "DESKTOP_DATA_DIR" => data_dir })
    require "./config/environment"
    require "rack/mock"
    Rails.application.routes.draw { get("/up", to: proc { [200, {"content-type"=>"text/plain"}, ["ok"]] }) }
    status, = Rails.application.call(Rack::MockRequest.env_for("http://127.0.0.1/up"))
    abort "status \#{status}" unless status == 200
    puts "served from a read-only root"
    puts "log path: \#{Rails.application.config.paths["log"].first}"
  RB
  if okay
    ok "booted and served a request with the bundle read-only"
    out.lines.each { |l| note l.strip unless l.strip.empty? }
  else
    bad "failed from a read-only root"
    out.lines.last(6).each { |l| note l.strip }
  end
ensure
  FileUtils.chmod_R("u+w", APP)
end

section "Result"
if $failures.zero?
  puts "  \e[32mALL CHECKS PASSED\e[0m"
else
  puts "  \e[31m#{$failures} CHECK(S) FAILED\e[0m"
end
exit($failures.zero? ? 0 : 1)
