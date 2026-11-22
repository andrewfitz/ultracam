import Foundation
import XCTest
let suite = XCTestSuite(name: "Program cadence CPU")
let cadence = XCTestSuite(forTestCaseClass: ProgramCadenceCPUChecks.self)
if ProcessInfo.processInfo.environment["ULTRACAM_CADENCE_LOW_RATE_ONLY"] == "1" {
  for test in cadence.tests where test.name.contains("testLowRateSchedules") { suite.addTest(test) }
} else if ProcessInfo.processInfo.environment["ULTRACAM_CADENCE_EDGES_ONLY"] == "1" {
  for test in cadence.tests where test.name.contains("testResetAndTopology") || test.name.contains("testMissedWake") { suite.addTest(test) }
} else {
  suite.addTest(XCTestSuite(forTestCaseClass: ProcessedFrameChecks.self))
  suite.addTest(cadence)
  suite.addTest(XCTestSuite(forTestCaseClass: ProgramStageRetentionChecks.self))
}
suite.run()
guard let run = suite.testRun, run.executionCount > 0 else { exit(2) }
exit(run.hasSucceeded ? 0 : 1)
