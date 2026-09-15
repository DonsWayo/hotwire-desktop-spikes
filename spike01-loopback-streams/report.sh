#!/bin/bash
# Read results.jsonl and say what happened, rather than leaving a JSONL file to
# interpret. The server's own lines are the ground truth: a suspended page
# cannot report on itself.
cd "$(dirname "$0")"
[ -f results.jsonl ] || { echo "No results.jsonl — has the harness run?"; exit 1; }

mise exec ruby@3.4.8 -- ruby -rjson -e '
  events = File.readlines("results.jsonl").filter_map { |l| JSON.parse(l) rescue nil }

  opens  = events.select { |e| e["event"] == "connection.open" }
  closes = events.select { |e| e["event"] == "connection.close" }
  gaps   = events.select { |e| e["kind"] == "gap" }
  missed = events.select { |e| e["kind"] == "missed" }
  sleeps = events.select { |e| %w[visibility online offline].include?(e["kind"]) }

  green = "\e[32m"; red = "\e[31m"; dim = "\e[36m"; off = "\e[0m"
  puts
  puts "\e[1m==> What the server saw\e[0m"
  %w[sse websocket].each do |transport|
    o = opens.count  { |e| e["transport"] == transport }
    c = closes.count { |e| e["transport"] == transport }
    mark = c.zero? && o.positive? ? "#{green}held#{off}" : "#{red}dropped #{c}x#{off}"
    puts "  #{transport.ljust(10)} opened #{o}, closed #{c}   #{mark}"
  end

  if closes.any?
    puts
    puts "\e[1m==> Every close, with the reason\e[0m"
    closes.each { |e| puts "  #{e["at"][11, 8]}  #{e["transport"].ljust(10)} #{e["reason"]}" }
  end

  puts
  puts "\e[1m==> What the page saw\e[0m"
  if gaps.empty? && missed.empty?
    puts "  #{green}no gaps over 3s and no missed sequence numbers#{off}"
  else
    gaps.first(10).each { |e| puts "  #{red}gap#{off}    #{e["transport"].ljust(10)} #{e["gap_ms"]}ms" }
    missed.first(10).each { |e| puts "  #{red}missed#{off} #{e["transport"].ljust(10)} #{e["lost"]} between #{e["from"]} and #{e["to"]}" }
    puts "  #{dim}(#{gaps.size} gaps, #{missed.size} missed in total)#{off}" if gaps.size + missed.size > 20
  end

  puts
  puts "\e[1m==> Events during the run\e[0m"
  if sleeps.empty?
    puts "  #{dim}none recorded — was the display actually slept?#{off}"
  else
    sleeps.group_by { |e| e["kind"] }.each { |kind, list| puts "  #{kind.ljust(12)} #{list.size}" }
  end

  first = events.first&.dig("at"); last = events.last&.dig("at")
  puts
  puts "\e[1m==> Verdict\e[0m"
  held = %w[sse websocket].select { |t| closes.none? { |e| e["transport"] == t } && opens.any? { |e| e["transport"] == t } }
  if held.size == 2
    puts "  #{green}PASS#{off} both transports held. SSE is the default by choice, not necessity."
  elsif held.size == 1
    puts "  #{green}PASS#{off} #{held.first} held; the other dropped. Default to #{held.first}."
  else
    puts "  #{red}FAIL#{off} neither transport survived. Per the study, this stops the project:"
    puts "       every DOM update would have to cross a process boundary as a string."
  end
  puts "  #{dim}#{first} to #{last}, #{events.size} events#{off}" if first
'
