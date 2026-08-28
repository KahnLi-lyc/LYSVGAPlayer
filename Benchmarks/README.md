# LYSVGAPlayer Benchmarks

The benchmark target records deterministic simulator measurements for:

- SVGA 1.x and 2.x parsing;
- V2 image preparation and first-frame rendering;
- 300 rendered frames, including wall time, process CPU time, sampled resident memory, and the proportion of frames exceeding the source frame budget.

Run it on a fixed simulator and write a JSON result:

```bash
Benchmarks/run.sh "platform=iOS Simulator,id=<SIMULATOR_UDID>" Benchmarks/Results/lysvga.json
```

`Benchmarks/Results/` is intentionally ignored because measurements depend on the machine, simulator runtime, build configuration, and thermal state. The dropped-frame value is a deterministic render-budget proxy, not a replacement for Instruments or physical-device display-link measurement.

To compare with an independently measured SVGAPlayer-iOS 2.5.8 result using the same assets, output size, iteration counts, simulator, and build configuration:

```bash
ruby Benchmarks/compare_results.rb Benchmarks/Results/lysvga.json Benchmarks/Results/upstream-2.5.8.json
```

The comparison fails when parsing, first-frame time, or CPU exceeds 110% of upstream, peak resident memory exceeds 115%, or the over-budget frame rate increases by more than one percentage point. No threshold claim is valid until both JSON files come from the same controlled environment.
