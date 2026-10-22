import XCTest

// The MonitorKit host checks: MonitorFeedHost and MonitorGPUContext against the
// real library, built with every app source (scripts/monitor-feed-host-checks.sh).
let suite = XCTestSuite(name: "Ultracam MonitorKit host checks")
suite.addTest(XCTestSuite(forTestCaseClass: MonitorFeedHostChecks.self))
suite.run()
guard let run = suite.testRun, run.executionCount > 0 else { exit(2) }
exit(run.hasSucceeded ? 0 : 1)
