# Bug audit verification — 2026-11-05

This follow-up checked reported defects against production call paths and existing
contracts. It excludes impossible-input hardening and feature requests. Changes
from other work already present in the shared working tree were preserved.

## Confirmed changes

- Camera stream lifecycle checks compare queue identity, rather than queue labels
  or a marker shared by unrelated runtime queues. Regression coverage exercises
  both separate runtime queues and runtimes sharing the same queue.
- Virtual-camera publication no longer waits for CMIO acknowledgement on the main
  actor. Pending publications coalesce; transport admission rejects older local
  intent so delayed work cannot overwrite a newer capture handshake.
- The recording sidebar offers Choose Folder when idle without a default folder.
- Auto startup with no capture timestamp leaves clock ownership unset until the
  first real update. Previously a first timestamp of 1,000 seconds immediately
  forced a maximum-duration cut from a shot incorrectly seeded at zero. The app
  regression was observed failing before the fix.
- Added regression coverage for recording cancellation preserving a directory or
  symlink at the partial-file path, while deleting an owned regular partial and
  releasing its reservation.
- Added regression coverage rejecting a failed XCTest suite even when its test
  count matches the expected coverage.

## Reports rejected after verification

- Fixed-interval Hold already propagates to the coordinator and is tested.
- The synchronous camera toggle has no production callers; the production async
  setter already updates frame demand when the enabled state is unchanged.
- Program Source and Output readings already coincide without a LUT; forcing
  stored stages to Output did not fix a demonstrated rendering failure.
- AudioMeter.flush is a publication operation used during continuous audio, not
  LoudnessMeter's end-of-run operation. Discarding partial ticks broke existing
  tests. The flush change was reverted, as was the unsupported PPM carry reset.
  A regression now explicitly preserves partial loudness ticks across publication.
- Extension preflight status depends on the running binary's signing state, not
  the installed extension state; the earlier stale-install-status report did not
  establish a defect.
- No demonstrated native CMIO failed-start/stop sequence supported changing
  authorization bookkeeping. No speculative lifecycle change was made.
- The timeline acknowledgement caller checks the pending target before recording
  an applied cut; arbitrary mismatched-target calls do not establish a product bug.

## Validation

- 79 build-contract tests passed, including failed-suite rejection.
- 40 MonitorKit audio control, loudness, and discontinuity tests passed after
  restoring the original audio implementation.
- 85 camera registry, recording output, source audio, and registry publication
  tests passed in the initial combined harness.
- Two focused publisher tests passed against the actual registry/transport sources
  with strict concurrency and warnings treated as errors, including stale intent.

- Final complete app test harness compiled with strict concurrency and warnings
  treated as errors. Its affected suites passed: 207 tests, zero failures,
  including the startup-clock and stale-publication regressions.
- Unsigned Ultracam Debug build succeeded after the final changes; root and
  MonitorKit diff whitespace checks passed.
