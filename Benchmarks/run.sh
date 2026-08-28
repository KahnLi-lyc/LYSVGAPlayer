#!/bin/bash

set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
destination="${1:-platform=iOS Simulator,name=iPhone 17 Pro}"
output="${2:-$repository_root/Benchmarks/Results/lysvga.json}"
log_file="$(mktemp -t lysvga-benchmark.XXXXXX.log)"
trap 'rm -f "$log_file"' EXIT

mkdir -p "$(dirname "$output")"
cd "$repository_root"
xcodebuild \
  -scheme LYSVGAPlayer \
  -destination "$destination" \
  -derivedDataPath .build/BenchmarkDerivedData \
  -only-testing:LYSVGABenchmarks \
  test | tee "$log_file"
ruby Benchmarks/collect_results.rb "$log_file" "$output"
