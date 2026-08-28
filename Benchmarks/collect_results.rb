# frozen_string_literal: true

require "json"
require "time"

abort "Usage: collect_results.rb XCODEBUILD_LOG OUTPUT_JSON" unless ARGV.length == 2

results = File.readlines(ARGV[0], chomp: true).filter_map do |line|
  marker = "LYSVGA_BENCHMARK_RESULT "
  next unless (index = line.index(marker))

  JSON.parse(line[(index + marker.length)..])
end
abort "No benchmark result markers found in #{ARGV[0]}" if results.empty?

document = {
  "schemaVersion" => 1,
  "generatedAt" => Time.now.utc.iso8601,
  "results" => results.sort_by { |result| result.fetch("name") },
}
File.write(ARGV[1], JSON.pretty_generate(document) + "\n")
puts "Wrote #{results.length} benchmark results to #{ARGV[1]}"
