# LYSVGAPlayer Benchmarks

The benchmark target records controlled simulator or physical-device measurements for:

- SVGA 1.x and 2.x parsing;
- V2 end-to-end first-playable latency from encoded Data through parsing, image preparation, layer construction, layout, and first pixel rendering;
- warm first-frame rendering diagnostics after a video model already exists;
- 300 rendered frames, including wall time, process CPU time, sampled resident memory, and the proportion of frames exceeding the source frame budget.

Run it on a fixed simulator and write a JSON result:

```bash
Benchmarks/run.sh "platform=iOS Simulator,id=<SIMULATOR_UDID>" Benchmarks/Results/lysvga.json
```

The XCTest benchmark target is for Simulator runs. Swift Package test bundles are not installed as a standalone physical-device runner by this script. For a physical device, use the app-hosted runner in `Demo/LYSVGADemo`: build the Demo in Release, install the app, upload the private fixture to its Documents directory, then launch it with `LYSVGA_DEVICE_BENCHMARK=1`. The app writes `lysvga-device-benchmark.json` to Documents and exits after completion.

```bash
ios-deploy --id <DEVICE_UDID> --bundle_id com.lysvga.demo \
  --upload TestAssets/Local/head_wear_vip9.svga \
  --to Documents/head_wear_vip9.svga --no-wifi

ios-deploy -d -I -u --id <DEVICE_UDID> \
  --bundle <RELEASE_LYSVGADEMO_APP> \
  --args '' \
  --envs LYSVGA_DEVICE_BENCHMARK=1
```

The script always builds the benchmark target in Release with testability enabled. `first-playable.v2` clears the explicit prepared-image cache before every run, warms up 3 times, measures 30 times, and records the median as `wallMilliseconds` plus `p95WallMilliseconds`; its timer ends at the first rendered pixel and does not include the follow-up image preheat wait. The harness then waits for that preheat to quiesce before the next iteration. `continuous-render.v2` resets the image cache, prepares one renderer, waits for its two-stage image pipeline to finish, and measures steady-state frame updates. Parse, image preparation, layer/layout, render, CPU, layer-count, and peak-memory fields remain diagnostics. `first-frame.v2` is retained as a warm-path diagnostic and is not a pass/fail threshold.

The app-hosted runner reads `head_wear_vip9.svga` from Documents by default; `LYSVGA_BENCHMARK_ASSET` can select another uploaded filename. The XCTest runner uses `Fixtures/local-business.svga` when present and otherwise falls back to `rose_2.0.0.svga`. Both private paths are Git-ignored and must not be committed.

`Benchmarks/Results/` is intentionally ignored because measurements depend on the machine, simulator runtime, build configuration, and thermal state. The dropped-frame value is a deterministic render-budget proxy, not a replacement for Instruments or physical-device display-link measurement.

To compare with an independently measured SVGAPlayer-iOS 2.5.8 result using the same assets, output size, iteration counts, simulator, and build configuration:

```bash
ruby Benchmarks/compare_results.rb Benchmarks/Results/lysvga.json Benchmarks/Results/upstream-2.5.8.json
```

The comparison fails when parsing or median end-to-end first-playable time exceeds 110% of upstream, continuous-render CPU exceeds 110%, peak resident memory exceeds 115%, or the over-budget frame rate increases by more than one percentage point. No threshold claim is valid until both JSON files come from the same device, asset, output size, Release configuration, warmup/iteration count, and comparable thermal state.
