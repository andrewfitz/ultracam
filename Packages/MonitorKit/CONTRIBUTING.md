# Contributing to MonitorKit

Thank you for helping. Bug reports, fixes, tests, documentation and new monitoring tools are all welcome. This guide covers building, testing and the rules every change has to follow.

By taking part you agree to the [Code of Conduct](CODE_OF_CONDUCT.md). Please report security vulnerabilities privately, as [SECURITY.md](SECURITY.md) describes, not in a public issue.

## Before you start

- For a bug, open an issue with the [bug report form](https://github.com/andrewfitz/MonitorKit/issues/new/choose). Give the macOS and Xcode versions, the GPU, the source pixel format and a minimal reproduction.
- For a new feature or a public API change, open a feature request first so the design can be agreed before you write code. Until 1.0.0 a minor release may change the public API, but every change has to be deliberate and listed in the [changelog](CHANGELOG.md).
- Small fixes (typos, documentation, an obvious bug with a test) can go straight to a pull request.

## Requirements

- A Mac with Apple silicon, running macOS 26 or later.
- Xcode 26 or later (Swift 6.2 tools or newer) to build the library. Running the tests needs Xcode 26.6 or later: Swift 6.2's type checker gives up on some test expressions. CI builds with Xcode 26.0.1 (the oldest supported), and builds and tests with Xcode 26.6 on macOS 26 and Xcode 27 on macOS 27.
- No Metal toolchain: the shaders are `.msl` text resources, compiled at runtime by the OS.
- No third-party dependencies. Please don't add any.

## Build and test

These are the commands CI runs:

```sh
swift build
swift build -c release
swift test
```

Check that the libraries also compile for iOS:

```sh
xcodebuild build -scheme MonitorKit-Package -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO
```

To run part of the suite, pass `--filter` a regular expression over `Module.Class/test`:

```sh
swift test --filter MonitorKitCoreTests
swift test --filter 'MonitorKitScopesTests.ScopeRenderTests'
```

Tests that need a Metal device skip (`XCTSkip`) when there is none. Tests that need a GPU feature skip when the device lacks it, with the reason: every GPU test needs an `MTLResidencySet` and MonitorKit's Metal Shading Language version, and the Metal 4 tests need `MTLGPUFamily.metal4`, an `MTL4CommandQueue` and an `MTL4Compiler`. Each test target's `GPUCapabilities.swift` holds these checks. A device that has the features and still fails, for example on a shader that does not compile, fails the test.

### Metal validation

GPU changes must pass the whole suite under Metal API validation and shader validation:

```sh
MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION=1 swift test
```

Validation slows encoding and every shader several times, and the debug layer allocates inside Metal calls. So under these variables the timing benchmarks and heap allocation counts skip themselves. Run validation and benchmarks as separate passes.

### Benchmarks

The benchmark classes check their budgets on GPU timestamps and CPU clocks. The budgets were set on an M4 Max and are listed in the README and [ARCHITECTURE.md](Docs/ARCHITECTURE.md). Run them on a quiet machine, with no other builds or GPU work going on:

```sh
swift test --filter 'Benchmark'
```

This matches `Benchmarks`, `Metal4Benchmarks`, `ScopeBenchmarkTests`, `ScopeMetal4Benchmarks`, `GPUBenchmarks`, `TickBenchmarks` and `PipelineArchiveBenchmarks` (which runs only when asked for, below). `PerformanceRegressionTests` is not a benchmark: it checks that the optimised shaders give bit-for-bit the same pixels as the baseline shaders and that a feed releases memory it no longer needs, and it runs with the rest of the suite. Each result prints on a line that starts with `BENCH`. A benchmark that misses its budget is measured again, a few rounds at most. Some benchmarks skip, printing the numbers, when every round misses on a machine whose load average is above its performance core count. Treat a miss on a quiet machine as a regression.

Pipeline warm-start timing (cold and warm compiles, tens of seconds) runs only when asked for:

```sh
MONITORKIT_WARMSTART_BENCH=1 MONITORKIT_WARMSTART_ROUNDS=3 swift test --filter PipelineArchiveBenchmarks
```

### Environment variables

| Variable | Effect |
| --- | --- |
| `MONITORKIT_CI=1` | Set by the CI workflow. GitHub-hosted macOS runners are virtual machines whose paravirtual GPU may not support Metal 4 and whose timings mean nothing. With this variable set, the timed benchmark classes skip and the timing budgets inside other tests are not checked; their pixel and correctness checks still run. Tests that need a GPU feature skip without it whether or not this is set. Set it locally to reproduce a CI run. |
| `MONITORKIT_TEST_NO_METAL4=1` | Report Metal 4 as missing, so the Metal 4 tests skip as on a device without `MTLGPUFamily.metal4`. Use it to check that the rest of the suite does not depend on Metal 4. |
| `CI` | Set by GitHub Actions. The realtime audio timing assertions are not checked when it (or `MONITORKIT_CI=1`) is set. |
| `MONITORKIT_ASSERT_TIMING=1` | Assert the realtime audio timings even when `CI` is set. |
| `MONITORKITUI_WINDOW_TESTS=1` | Run the display-link tests that open an on-screen window. |
| `MONITORKIT_WARMSTART_BENCH=1` | Run the pipeline warm-start benchmarks. `MONITORKIT_WARMSTART_ROUNDS` sets the rounds (default 3). |
| `MTL_DEBUG_LAYER=1`, `MTL_SHADER_VALIDATION=1` | Metal API and shader validation. Timing and allocation tests skip. |

## Rules for code

MonitorKit's promise is to cost no more than code written directly into the host. [ARCHITECTURE.md](Docs/ARCHITECTURE.md) sets out that contract, and a change that breaks it won't be merged.

- **Match the surrounding code.** Use two-space indentation, the existing naming and the existing doc comment style. Every public symbol gets a doc comment that says what it does, its units and its threading rules.
- **Warnings are errors.** Every target builds with `treatAllWarnings(as: .error)` in Swift 6 language mode with strict concurrency. Fix warnings; don't silence them.
- **Nothing on the frame path allocates.** That covers per-frame encoding, per-buffer audio and per-tick view code, in debug builds as well as release. Use `while` loops there, not `for i in 0..<n`, because `Range` iteration heap-allocates on every step in unoptimised builds. Don't use closures that capture, string formatting, array or dictionary growth, existentials or bridging on that path. The allocation tests count heap allocations per steady-state frame, and that count must stay 0.
- **No copies, queues, threads, commits, waits or readbacks.** MonitorKit borrows the host's textures and command buffers. It encodes into them and returns. It never creates a command queue, never commits or waits on a command buffer, and never reads GPU results back on the frame path. Classic `MTLCommandBuffer` and Metal 4 `MTL4CommandBuffer` encodes must produce bit-identical output.
- **Every constant has a source.** Coefficients, curves, thresholds and colours come from a published standard or a manufacturer document. Cite the source in [MATH.md](Docs/MATH.md) next to the formula.
- **Public API changes** go in the changelog under **Added**, **Changed** or **Removed**, and in [API.md](Docs/API.md).

## Rules for tests

- Every change comes with tests. A bug fix includes a test that fails without the fix.
- **GPU math needs a CPU reference.** Each GPU result is compared with a CPU implementation in `MonitorKitCore`. The comparison is exact at classification boundaries and within a stated tolerance elsewhere (see the tolerances in the README and MATH.md). Add the reference first, test it against the published values, then test the shader against the reference.
- Test both encode paths, classic and Metal 4, when a change touches encoding.
- A test that needs a GPU feature must skip cleanly (`XCTSkip`) when the device lacks it, so the suite passes on CI runners and Macs without that feature.
- Performance-sensitive code gets a benchmark with a budget, or extends an existing one.

## Pull requests

1. Fork the repository and branch from `main`.
2. Make your change, keeping it focused on one problem. Unrelated refactors belong in separate pull requests.
3. Run `swift build`, `swift build -c release` and `swift test`. For GPU changes, also run the suite under Metal validation and run the benchmarks.
4. Update the documentation in `Docs/` and the changelog under the next version.
5. Open the pull request and fill in its template. CI must pass before review.

Write commit messages in the imperative mood, with a short summary line ("Fix vectorscope target placement for BT.2020"). Put the reasoning in the body when it is not obvious.

## License

MonitorKit is licensed under the [Apache License 2.0](LICENSE). Under section 5 of the license, any contribution you intentionally submit for inclusion is licensed under the same terms. There is no separate contributor agreement.
