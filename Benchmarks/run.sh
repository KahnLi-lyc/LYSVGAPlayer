#!/bin/bash

set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
destination="${1:-platform=iOS Simulator,name=iPhone 17 Pro}"
output="${2:-$repository_root/Benchmarks/Results/lysvga.json}"
log_file="$(mktemp -t lysvga-benchmark.XXXXXX.log)"
trap 'rm -f "$log_file"' EXIT

build_arguments=(
  -scheme LYSVGAPlayer
  -configuration Release
  -destination "$destination"
  -derivedDataPath .build/BenchmarkDerivedData
  ENABLE_TESTABILITY=YES
  -only-testing:LYSVGABenchmarks
  test
)
if [[ "$destination" == *"Simulator"* ]]; then
  build_arguments+=(CODE_SIGNING_ALLOWED=NO)
elif [[ -n "${LYSVGA_DEVELOPMENT_TEAM:-}" ]]; then
  build_arguments=(
    -allowProvisioningUpdates
    "${build_arguments[@]}"
    CODE_SIGN_STYLE=Automatic
    DEVELOPMENT_TEAM="$LYSVGA_DEVELOPMENT_TEAM"
  )
else
  echo "LYSVGA_DEVELOPMENT_TEAM is required when benchmarking on a physical device." >&2
  exit 2
fi

mkdir -p "$(dirname "$output")"
cd "$repository_root"
xcodebuild "${build_arguments[@]}" | tee "$log_file"
ruby Benchmarks/collect_results.rb "$log_file" "$output"
