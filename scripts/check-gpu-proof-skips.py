#!/usr/bin/env python3
"""Fail required proof lanes on skips except explicitly named opt-in lanes.

This gates completed XCTest logs, not suite discovery or process success.
Unknown skipped tests fail closed in the required lane. Ordinary developer
runs remain permissive and visibly report incomplete coverage.
"""
import argparse
import os
from pathlib import Path
import re

# Exact optional lanes and the prerequisite flag that requests their execution.
# Other tests in these classes remain required; no class-wide exemptions.
OPTIONAL_PACKAGE_CASES = {
    'MonitorKitCoreTests.Perf01GuideGridTests/testWideGridMicrobenchmark': 'MONITORKIT_PERF01_GRID_BENCH',
    'MonitorKitCoreTests.Fresh02ColorMatrixPerformanceTests/testOldAndNewColorMatrixMicrobenchmark': 'MONITORKIT_FRESH02_BENCH',
    'MonitorKitAudioTests.Fresh14CorrelationTests/testCorrelationAndInitializationMicrobenchmark': 'MONITORKIT_FRESH14_BENCH',
    'MonitorKitTests.PipelineArchiveBenchmarks/testWarmUpDuration': 'MONITORKIT_WARMSTART_BENCH',
    'MonitorKitTests.PipelineArchiveBenchmarks/testInitAndWarmUpWithSeveralFiles': 'MONITORKIT_WARMSTART_BENCH',
    'MonitorKitTests.PipelineArchiveBenchmarks/testTimeToFirstSpecializedFrame': 'MONITORKIT_WARMSTART_BENCH',
    'MonitorKitUITests.DisplayLinkTests/testDisplayLinkDrawsAndPresents': 'MONITORKITUI_WINDOW_TESTS',
    'MonitorKitUITests.DisplayLinkTests/testHostDrivenLinkOnARenderThread': 'MONITORKITUI_WINDOW_TESTS',
    'MonitorKitUITests.MeterLayerTests/testLayersLandWhereTheViewSays': 'MONITORKITUI_WINDOW_TESTS',
    'MonitorKitUITests.MeterLayerTests/testALiveMeterTicksOnlyOnScreen': 'MONITORKITUI_WINDOW_TESTS',
    'MonitorKitTests.PipelineArchiveValidationTests/testAValidatedSessionBuildsAndWritesNothing': 'MTL_SHADER_VALIDATION',
}


def skipped_cases(text):
    result = set()
    for identity in re.findall(r"^Test Case '([^']+)' skipped[^\n]*", text, re.MULTILINE):
        objc = re.fullmatch(r'-\[([^ ]+) ([^]]+)\]', identity)
        result.add(f'{objc[1]}/{objc[2]}' if objc else identity)
    return sorted(result)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--app', action='store_true')
    mode.add_argument('--package', action='store_true')
    parser.add_argument('log', type=Path)
    args = parser.parse_args()
    cases = skipped_cases(args.log.read_text(errors='replace'))
    optional = set(cases) & OPTIONAL_PACKAGE_CASES.keys() if args.package else set()
    # Once explicitly requested, a lane must execute, even if setup fails.
    def requested(flag):
        if flag == 'MTL_SHADER_VALIDATION':
            # MonitorPipelineArchive.shaderValidation: present and not "0".
            return flag in os.environ and os.environ[flag] != '0'
        return os.environ.get(flag) == '1'
    optional = {case for case in optional if not requested(OPTIONAL_PACKAGE_CASES[case])}
    required = sorted(set(cases) - optional)
    label = 'MonitorKit package' if args.package else 'App runtime'
    for case in cases:
        print(f'{label}: skipped {case} ({"optional opt-in lane; coverage incomplete" if case in optional else "coverage incomplete"})')
    if required and os.environ.get('ULTRACAM_REQUIRE_GPU_PROOFS') == '1':
        print(f'{label}: required GPU proof lane refuses {len(required)} unclassified/required skipped cases')
        return 1
    if not cases:
        print(f'{label}: no skipped tests')
    return 0

if __name__ == '__main__':
    raise SystemExit(main())
