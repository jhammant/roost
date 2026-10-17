import XCTest
@testable import RoostCore

/// Every module polls from a dispatch block that never returns, so GCD never drains that
/// block's autorelease pool. Without a pool per poll, each run's output and parsed JSON
/// stayed alive: Roost reached 37 GB after six days of atc's 676 KB --json every 5 s.
final class PollLoopTests: XCTestCase {
    private func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        _ = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return Double(info.phys_footprint) / 1_000_000
    }

    func testPollingDoesNotKeepEveryRunsOutput() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("roost-poll-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let items = (0..<4000).map { #"{"title": "session \#($0), working on something long enough to matter"}"# }
        let menu = dir.appendingPathComponent("menu.json")
        try #"{"title": "Big", "items": [\#(items.joined(separator: ","))]}"#.write(to: menu, atomically: true, encoding: .utf8)
        var manifest = try PluginManifest.parse(["id": "big", "command": ["/bin/cat", menu.path]], folderName: "big")
        manifest.interval = 0.001
        let plugin = PluginModule(manifest: manifest, directory: dir)

        let polls = 150
        let done = expectation(description: "\(polls) polls")
        done.expectedFulfillmentCount = polls
        done.assertForOverFulfill = false
        let before = footprintMB()
        plugin.start { done.fulfill() }
        wait(for: [done], timeout: 60)
        plugin.stop()

        let grown = footprintMB() - before
        XCTAssertLessThan(grown, 40, "\(polls) polls of a \(items.count)-item menu grew the footprint by \(Int(grown)) MB")
    }
}
