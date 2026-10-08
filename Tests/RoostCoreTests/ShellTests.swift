import XCTest
@testable import RoostCore

/// Roost runs a command every few seconds for days, so a runner that leaves a pipe open per
/// run eventually hits the open-file limit, and then every module reads empty output.
final class ShellTests: XCTestCase {
    private func openDescriptors() -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? -1
    }

    private func assertNoLeak(_ argv: [String], timeout: TimeInterval = 30, runs: Int = 200,
                              file: StaticString = #filePath, line: UInt = #line) {
        _ = Shell.run(argv, timeout: timeout)  // warm up anything Foundation opens once
        let before = openDescriptors()
        for _ in 0..<runs { _ = Shell.run(argv, timeout: timeout) }
        let after = openDescriptors()
        XCTAssertLessThan(after - before, 5, "\(runs) runs of \(argv[0]) left \(after - before) files open",
                          file: file, line: line)
    }

    func testOrdinaryRunsCloseTheirPipes() {
        assertNoLeak(["/bin/echo", "{}"])
    }

    func testFailingRunsCloseTheirPipes() {
        assertNoLeak(["/bin/sh", "-c", "echo oops >&2; exit 3"])
    }

    func testCommandsThatAreNotFoundOpenNothing() {
        assertNoLeak(["/no/such/tool"])
    }

    func testTimedOutRunsCloseTheirPipes() {
        assertNoLeak(["/bin/sleep", "5"], timeout: 0.2, runs: 20)
    }

    func testOutputStillArrives() {
        let result = Shell.run(["/bin/sh", "-c", "printf '{\"title\": \"ok\"}'; echo warn >&2"])
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.output, "{\"title\": \"ok\"}")
        XCTAssertEqual(result.stderr, "warn\n")
    }
}
