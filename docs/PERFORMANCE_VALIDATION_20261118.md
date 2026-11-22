# Performance follow-up validation — 2026-11-18

This check closes integration validation for three performance changes from the November 5 follow-up. It does not count the separate correctness fixes as optimizations.

| Operation | Earlier measured before → after | Change |
| --- | --- | --- |
| Paired 24-bit PCM, stereo / 16 channels | 3,308 → 2,871 ns / 11,829 → 4,582 ns | Pack into CMBlockBuffer storage directly; remove temporary Data and copy. |
| Camera metadata copy path | 0.498 → 0.316 µs | Add pause metadata to the queue's existing independent copy. |
| LUT color attachment stamping | roughly 11.2 → 10.3 µs | Replace three per-frame dictionaries with enum switches. |

These are historical local-operation measurements, not newly measured app-wide CPU, FPS, memory, or GPU improvements. No additional MonitorKit optimization qualified in this follow-up.

Validation uses a frozen copy of the current app (HEAD c9f4a16 plus working-tree changes) and sibling MonitorKit (HEAD 5bf8dfe plus working-tree changes). Sources, SDK inputs, tests, and build scripts are copied to `/Volumes/8TB/cinesomatic-build/performance-check-20261118/`; `source-hashes.json` records 908 inputs. Only the copied test compile command enables four jobs and whole-module optimization; strict concurrency and warnings-as-errors remain enabled. The live checkout is not used as the compiler's source input.

Validation completed:

- Full app/test binary compiled successfully with strict concurrency and warnings-as-errors, linked against the freshly built MonitorKit release products.
- 17 affected app suites: 84 tests passed, zero failures or skips. Coverage includes PCM byte equivalence, camera buffer lifetime and metadata isolation, LUT color declarations, GPU conversions, ownership, and recording burn-in.
- All five MonitorKit XCTest bundles completed: 1104 passed, 11 skipped, 0 failed; command exited 0. No retry or threshold adjustment was used.
- Snapshot inputs still matched the live source files after the app run (excluding the intentional snapshot-only compiler flags).

Evidence: `compile-run.log`, `app-targeted-tests.log`, `monitor-tests.log`, `source-hashes.json`, and `live-drift.json` in the external directory above. These checks found no regressions in their coverage; they do not establish whole-app live-camera performance or cover every app test. Later changes require separate validation.
