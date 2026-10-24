# MonitorKit performance pass

Date: 2026-10-24

This pass started from the current `main` implementation and used measured CPU, GPU, allocation, memory, package, host, app-integration, and UI checks. The Metal 4 and specialized-pipeline paths were retained because they were already the fastest or equivalent measured path on this machine; changes were limited to verified work reduction and lifetime fixes.

## Changes merged to `main`

The delegated performance commits are on `main` as `dbd76d2`, `15be010`,
`38a0534`, `5de3359`, `1b24974`, `2d03f2b`, and `cadecae`. Their original
agent branch tips remain available under the `archive/` tags after worktree
cleanup.

- `AudioMeter` computes peak decay once per audio chunk, skips disabled peak ballistics, and avoids building a true-peak envelope unless true peak or phase-based PPM needs it. The shared phase envelope dependency is preserved for PPM-only configurations.
- Code-range scaling for supported 8–16-bit depths uses exact integer shifts instead of repeated `pow` calls, with the existing fallback for invalid depths.
- Tiny navigator viewports now return an empty navigator and identity map instead of producing non-finite geometry.
- Failed asynchronous picture and compute pipeline builds release their pending keys so a failed specialization cannot retain memory or block recovery.
- Vectorscope SIMD atomic reduction sums only lanes targeting the leader bin, avoiding cross-bin overcounting while retaining the SIMD reduction.
- Audio meter session history is cleared when a consumer adopts or advances sessions, bounding retained meter state across repeated attach/detach cycles.
- Renderer frame-cache equality now includes layout, clean aperture, size, geometry, and processing state, so same-ID recycled frames with changed metadata are encoded instead of incorrectly skipped.

## Measured results

Release AudioMeter benchmarks before the pass and after the decay/work specialization measured:

| Workload | Before | After | Change |
| --- | ---: | ---: | ---: |
| 16 channels, all meters, 48 kHz | 67.28 µs | 64.13 µs | 4.7% faster |
| 16 channels, interleaved constant input | 94.13 µs | 91.91 µs | 2.4% faster |
| 16 channels, sample + true peak | 22.81 µs | 20.29 µs | 11.0% faster |
| 16 channels, peak + RMS + VU | 5.49 µs | 4.50 µs | 18.0% faster |
| 16-frame calls | 133.23 µs | 127.72 µs | 4.1% faster |
| 32-frame calls with 60 s RMS window | 93.40 µs | 86.80 µs | 7.1% faster |

The GPU picture path remains hardware accelerated. Existing measurements show Metal 4 reducing 4K-to-1080p tools-off GPU time from 0.112 ms classic to 0.106 ms render and 0.107 ms compute for rgba16Float, and from 0.106 ms classic to 0.103 ms render and 0.100 ms compute for bgra8. Specialized pipelines remain substantially cheaper than the all-tools variant. Fused scope accumulation continues to reduce separate scope passes to roughly 0.57–0.75 ms for the measured 4K cases.

Steady-state allocation checks remain at zero for MonitorKit rendering and audio processing. App integration measured zero heap allocations for frame-slot and frame-wrap handling, two picture encode allocations matching the inline Metal calls, and three allocations for the focus/zebra/guides path versus four inline calls. Freeze memory remains bounded at 22,282,240 bytes for a 4K v210 copy.

## Validation

- Full MonitorKit package suites passed after the corrected audio and GPU changes: UI 151 tests (2 opt-in skips), core MonitorKit 290 tests (4 validation/display skips), scopes 158 tests, and audio 79 tests.
- Post-merge targeted checks passed: renderer metadata regression (1), layout (7), and signal reference (7).
- `swift build --package-path Packages/MonitorKit -c release` passed.
- `bash scripts/monitor-kit-package.sh selftest` passed all cases.
- `bash scripts/monitor-feed-host-checks.sh` passed 19 tests.
- `bash scripts/monitor-app-integration.sh` passed at 30, 60, and 240 Hz; the 4K picture path measured 0.152 ms minimum / 0.201 ms median, and focus+zebra+guides measured 0.274 ms minimum / 0.301 ms median.
- `bash scripts/ui-typecheck.sh` passed.
- `FORCE=1 bash scripts/ui-verify.sh` passed 795 checks, 0 failures, 0 pending, and 189 images.

No safe measured optimization was found in the LUT storage, decode/texture cache, Metal 4 residency, classic Metal encoding, scope grouping, SwiftUI invalidation, or release-build settings. Those paths already reuse resources and avoid steady-state allocations; speculative changes were discarded.
