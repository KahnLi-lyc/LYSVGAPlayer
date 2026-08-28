/// Internal instrumentation hooks used by the repository benchmark harness.
@_spi(LYSVGABenchmark)
public enum LYSVGABenchmarkSupport {
    public static func resetPreparedImageCache() {
        LYSVGAImagePreparer.resetCacheForTesting()
    }
}
