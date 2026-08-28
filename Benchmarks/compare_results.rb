# frozen_string_literal: true

require "json"

abort "Usage: compare_results.rb CANDIDATE_JSON UPSTREAM_JSON" unless ARGV.length == 2

def indexed_results(path)
  JSON.parse(File.read(path)).fetch("results").to_h { |result| [result.fetch("name"), result.fetch("metrics")] }
end

candidate = indexed_results(ARGV[0])
upstream = indexed_results(ARGV[1])
checks = [
  ["parse.v1", "wallMilliseconds", 1.10, :ratio],
  ["parse.v2", "wallMilliseconds", 1.10, :ratio],
  ["first-playable.v2", "wallMilliseconds", 1.10, :ratio],
  ["continuous-render.v2", "cpuMilliseconds", 1.10, :ratio],
  ["continuous-render.v2", "peakResidentBytes", 1.15, :ratio],
  ["continuous-render.v2", "droppedFrameRate", 0.01, :absolute],
]

failed = false
checks.each do |name, metric, limit, mode|
  candidate_value = candidate.fetch(name).fetch(metric)
  upstream_value = upstream.fetch(name).fetch(metric)
  passed = if mode == :ratio
    candidate_value <= upstream_value * limit
  else
    candidate_value <= upstream_value + limit
  end
  failed ||= !passed
  comparison = mode == :ratio ? format("%.3fx", candidate_value.fdiv(upstream_value)) : format("%+.4f", candidate_value - upstream_value)
  puts format("%-26s %-24s candidate=%12.4f upstream=%12.4f delta=%9s %s", name, metric, candidate_value, upstream_value, comparison, passed ? "PASS" : "FAIL")
end

exit(failed ? 1 : 0)
