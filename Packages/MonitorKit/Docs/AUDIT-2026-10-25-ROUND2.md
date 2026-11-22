# MonitorKit follow-up audit and performance pass — 2026-10-25

Scope: `/Users/andrew/Projects/ai/MonitorKit`. This follows [round one](AUDIT-2026-10-25.md). All twenty fresh GPT-6.1 Sol reviewers audited the same twenty areas listed there, without inheriting the first review's conclusions. The coordinator integrated findings, reviewed numerical changes and ran repository-wide verification. MeterDisplay and LevelMeterView received additional explicit coverage during the performance pass. These changes were committed as 24356e5.

## Correctness changes

The following are **26 grouped defects**, not a count of every changed line or assertion. Performance-only changes are separate.

| # | Defect corrected |
| --- | --- |
| 1 | Integrated loudness and LRA saturated their histogram above +30 LUFS; fine bins now extend to +150 with a configured upper tail. |
| 2 | Finite extreme channel weights overflowed energy arithmetic; a common square-root scale is restored in log space. |
| 3 | Synchronous scope callers could compile the same pipeline concurrently; cold callers now join one compilation, including asynchronous work. |
| 4 | Mutating submission generations bypassed constructor invariants; setters enforce them too. |
| 5 | False-color encoding silently widened invalid nonfinite endpoints; only intended outward infinities are omitted. |
| 6 | Empty, reversed or NaN false-color bands consumed the retained-band limit. |
| 7 | ARRI false-color neutral code boundaries could enter the wrong zone through matrix rounding. |
| 8 | Whitespace-only LUT titles did not fall back to the filename. |
| 9 | Tiny GPU LUT domains flushed to zero while the CPU accepted them; upload now rejects unsupported spans. |
| 10 | Decode-stage focus masks remained valid after same-ID metadata changes. |
| 11 | Unknown-size warm-up omitted a filter specialization at extreme zoom. |
| 12 | Scope viewport dimensions, far edges or coverage area could overflow before rejection. |
| 13 | Metal 4 scope rendering did not extend the originating engine's accumulator residency lifetime. |
| 14 | Extreme VU rise times produced unstable rounded poles; configuration now checks stability. |
| 15 | Zero/negative custom scale factors lost the silence endpoint. |
| 16 | Scaling by the full maximum channel weight erased quiet channels beside a heavily weighted silent channel; square-root scaling preserves them. |
| 17 | Empty, offscreen or nonfinite leading surfaces incorrectly selected the native layer's color space. |
| 18 | Later owned-queue completion could incorrectly vouch for earlier uncommitted caller-owned work. |
| 19 | Guide Frame None uncovered another guide instead of clearing guides. |
| 20 | Selecting a fifth safe area silently evicted an already-selected area. |
| 21 | Fractional loudness targets used an absolute rather than relative rounded readout cache key. |
| 22 | Meter accessibility always announced true peak instead of the selected quantity and unit. |
| 23 | Extreme low-target EETF curves overshot and became nonmonotone; a documented monotone extension fixes that domain. |
| 24 | Correlation used uniform weights inside each callback chunk, making fast-window results depend on callback partitioning; it now implements exact exponential sample weights. |
| 25 | Biquad magnitude evaluation still overflowed for extreme finite coefficient sums; scaled complex evaluation covers that fallback. |
| 26 | Freeze mistook a shared primary texture for an unchanged frame; exact self-freeze still reuses storage, while changed aliased frames copy into fresh destinations. |

## Performance and algorithm decisions

- Cache immutable color matrices/inverses and ARRI zones; construct SIMD matrices without temporary arrays.
- Bound unmagnified guide generation once its exact retained segment prefix is complete.
- Collapse the Method C CPU chromaticity reconstruction and inverse transform algebraically, retaining validity guards and an independent full-form oracle.
- Share cold picture render, compute, focus and copy compilation across synchronous/asynchronous callers. Cached paths retain their existing fast lookup.
- Skip unused focus-mask work on clean/processed views; avoid guide geometry rebuilds for matte-opacity-only changes.
- Preserve scope dispatch/graticule caches across changes that do not affect their geometry.
- Reset dependency indices when replacing focus-mask storage while preserving old resource retirement.
- Reuse validated PPM coefficients at initialization, compute LRA bin centers only for selected percentiles, and skip unit weight-scale division.
- Preserve scene revisions for identical ordered handles; avoid temporary loudness channel arrays.
- A proposed precomputed loudness weight-ratio cache measured slower and was removed.

Measured on an Apple M4 Max, macOS 27.0.1. Local microbenchmarks (debug; isolated operation speedups are not whole-frame speedups):

| Operation | Reference/before | Current | Interpretation |
| --- | --- | --- | --- |
| Gamut conversion lookup | 1045.90 ns | 34.87 ns | ~30× faster |
| Matrix-to-SIMD adapter | 107.91 ns | 16.76 ns | ~6.4× faster |
| Extreme wide guide generation, 100 rounds | 81.49 ms | 0.780 ms | ~104× faster for this extreme aspect ratio |
| AudioMeter initialization | 3912.82 µs | 1944.97 µs | ~2× faster; separate local runs |
| Exact correlation, 16-channel meter, τ=.001 | 238.03 µs disabled | 239.58 µs enabled | ~0.65% incremental meter cost in this run |

The main all-tools 4K-to-1080p BGRA benchmark measured 0.302→0.304 ms classic, 0.295→0.295 ms Metal 4 render, and 0.295→0.298 ms Metal 4 compute: no material GPU regression. RGBA16 measured 0.317→0.307 ms classic. These are separate local runs, not controlled paired whole-application measurements. The baseline CPU benchmark skipped its budget on a loaded machine; the final picture CPU budgets passed, so no baseline/current CPU speedup is inferred from that comparison.

The Method C scalar implementation also measured faster than its retained full-form oracle; short measurements were variable, so no precise whole-application improvement is claimed.

### Quality choices retained deliberately

The production focus detector retains Scharr 3–10–3 derivatives, directional median support and L∞ magnitude. A GPU/CPU-checked L2 candidate reduced directional bias and cost about 1.7% extra GPU time, but raised background detections from 240 to 490 in the high-sensitivity noise fixture. It was not adopted. Candidate tests retain the comparison.

Scopes still count every source pixel and use maximum footprint reduction so isolated clipping survives display minification. This can broaden sparse events; it is not an integrated-density filter. Fractional picture minification retains bounded stratified sampling, and wide-footprint focus sampling remains approximate. Exact area/EWA filtering or focus max pyramids need additional fetches, passes or storage and have no demonstrated universal low-cost win here.

True peak retains the published Annex 2 FIR and its documented ripple and sub-48-kHz limitations. No claim of universally optimal detection or formal certification is made. Metal and Accelerate remain the appropriate existing libraries; no dependencies were added.

The EETF low-target extension is explicitly a MonitorKit convention, not a formula attributed to ITU. Ordinary-target arithmetic is unchanged. Tests compare CPU/GPU ramps, monotonicity, bounds and bit patterns. Loudness tests use stored-block references; correlation tests use scalar exponential recurrences across callback partitions. See [MATH.md](MATH.md) for formulas, primary sources and tolerances.

### Resource and contract changes

Default histogram bin storage grows by 96,000 bytes per loudness meter; exotic channel weights allocate an additional tail once at initialization. Exact correlation uses 8 KiB of preallocated Double scratch plus approximately 6 KiB of weight tables for its selected stereo pair. Neither allocates in the audio callback. GPU LUT uploads reject active spans below `Float.leastNormalMagnitude / Float.ulpOfOne`; CPU-only LUT sampling remains available for narrower domains. Submission completion values still depend on truthful host reporting.

## Remaining limitations

No audit can establish absence of every defect. iOS has build validation here, not a physical-device runtime pass. UIKit ancestor-hidden scheduling remains a follow-up because a reliable documented unhide notification is unavailable without extra observation/polling. Subpixel visible regions can still influence native layer color selection before target-size rounding; changing that requires coordinating the display driver and renderer. The 64-lane SIMD ballot correction from round one is not exercised on this GPU's narrower SIMD groups.

## Final validation

- Full normal suite: 1,001 tests, nine opt-in/validation-only skips, zero failures. This round adds 91 test methods in 33 new files over the saved baseline.
- The initial integration run exposed a debug-only generic collection boxing regression (32 allocations per 16-channel layout); concrete array-or-pair storage fixed it. Existing allocation tests and a new fixed-pair test pass without weakened assertions.
- Full `MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION=1 swift test`: 1,001 tests, 67 instrumentation/opt-in skips, zero failures. The exhaustive picture tests ran slowly under substantial unrelated machine load; process sampling confirmed active GPU correctness work.
- `MONITORKITUI_WINDOW_TESTS=1 swift test --skip-build --filter DisplayLinkTests`: both tests passed.
- `MONITORKIT_WARMSTART_BENCH=1 MONITORKIT_WARMSTART_ROUNDS=3 swift test --skip-build --filter PipelineArchiveBenchmarks`: all three tests passed. With Apple's system shader cache already warm, compiler/no-cache first specialized frame was 4.0 ms versus 5.7 ms with a warm disk archive. Fifteen-pipeline warm-up was 3.1 ms compiler/no-cache, 107.0 ms empty archive, and 3.2 ms warm archive (minimum of three). These measurements do not establish cold-system-cache performance or a universal benefit from disk archives.
- Final debug, release and generic iOS builds passed.
- `git diff --check` passed. No new dependencies or commits.

Validation logs are `/tmp/monitorkit-round2-verified-{normal,metal,window,warmstart,debug,release,ios}.log`; command exit statuses are recorded in `/tmp/monitorkit-round2-verification.json`.
