import XCTest
@testable import RoostCore

final class AgentsNeedsTests: XCTestCase {
    private let atc = "/usr/local/bin/atc"
    private let webURL = "https://example.com/atc"
    private let now = Date(timeIntervalSince1970: 1_767_225_600) // 2026-01-01 UTC

    private func fixture(_ name: String) throws -> [String: Any] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func build(_ model: [String: Any], webURL: String? = nil) -> (nodes: [MenuNode], badge: Badge?) {
        AgentsMenu.build(model: model, error: nil, providers: [], atc: atc, webURL: webURL, now: now)
    }

    func testUrgentNeedsComeFirstAndUseUrgentCountInsteadOfTotalOrJobs() throws {
        // Arrange
        let model = try fixture("needs")
        // Act
        let result = build(model, webURL: webURL)
        let titles = result.nodes.map(\.title)
        let header = try XCTUnwrap(titles.firstIndex(of: "Needs you"))
        // Assert
        XCTAssertEqual(result.badge, Badge("5", .alert))
        XCTAssertTrue(titles[header + 1].hasPrefix("Approve in atc web…"))
        XCTAssertTrue(titles[header + 2].hasPrefix("!  session-a"))
        XCTAssertTrue(titles[header + 3].hasPrefix("a-mail 3 approvals"))
        XCTAssertTrue(titles[header + 4].hasPrefix("a-mail request"))
        XCTAssertTrue(titles[header + 5].hasPrefix("a-mail device"))
        XCTAssertEqual(titles.filter { $0.hasPrefix("!  session-a") }.count, 1, "groups and needs must not duplicate sessions")
        XCTAssertFalse(titles.contains("Blocked on you"))
        XCTAssertTrue(titles.contains("◆  session-b · waiting 2h — Ready for review"))
    }

    func testNeedsKeepFastSessionJumpAndMailAnswerLocations() throws {
        // Arrange / Act
        let result = build(try fixture("needs"), webURL: webURL)
        let lines = MenuDump.lines(result.nodes)
        // Assert
        XCTAssertTrue(lines.contains { $0.contains("[run quietly: \(atc) --jump session-a --tty /dev/ttys003]") })
        XCTAssertTrue(lines.contains("· a-mail request — Answer at example.com."))
        XCTAssertTrue(lines.contains("· a-mail inbox — Answer in the a-mail app."))
        XCTAssertTrue(lines.contains("· a-mail 3 approvals — Answer in the a-mail app."))
        XCTAssertTrue(lines.contains("Open atc web    [open: \(webURL)]"))
    }

    func testApprovalOnlyOpensConfiguredWebURL() throws {
        // Arrange / Act
        let result = build(try fixture("approval"), webURL: webURL)
        let approval = try XCTUnwrap(result.nodes.first { $0.title.hasPrefix("Approve in atc web…") })
        // Assert
        XCTAssertEqual(result.badge, Badge("1", .alert))
        guard case .open(let target) = approval.action else { return XCTFail("Approval should open a URL") }
        XCTAssertEqual(target, webURL)
        XCTAssertTrue(approval.isEnabled)
        XCTAssertEqual(approval.toolTip, "Review details — Use atc web.")
    }

    func testMissingOrInvalidWebURLLeavesApprovalVisibleWithSetupHint() throws {
        // Arrange
        let model = try fixture("approval")
        for url in [nil, "", "  ", "file:///tmp/example", "javascript:example", "https://"] as [String?] {
            // Act
            let result = build(model, webURL: url)
            let approval = try XCTUnwrap(result.nodes.first { $0.title.hasPrefix("Approve in atc web…") })
            // Assert
            XCTAssertNil(approval.action)
            XCTAssertFalse(approval.isEnabled)
            XCTAssertTrue(approval.toolTip?.contains("ATC_WEB_URL") == true)
            XCTAssertFalse(result.nodes.contains { $0.title == "Open atc web" })
            XCTAssertEqual(result.badge, Badge("1", .alert))
        }
    }

    func testWebEntryIsAvailableBeforeFirstSuccessfulPoll() {
        // Act
        let result = AgentsMenu.build(model: nil, error: "Offline", providers: [], atc: atc, webURL: webURL)
        // Assert
        XCTAssertTrue(MenuDump.lines(result.nodes).contains("Open atc web    [open: \(webURL)]"))
        XCTAssertNil(result.badge)
    }

    func testMissingCountsDeriveUrgencyWithoutCountingMailProposalsOrInbox() throws {
        // Arrange
        var model = try fixture("needs")
        model.removeValue(forKey: "counts")
        // Act / Assert
        XCTAssertEqual(build(model).badge, Badge("5", .alert))
        model["needs"] = (model["needs"] as? [[String: Any]])?.filter {
            ["amail_proposal", "amail_inbox"].contains($0["kind"] as? String ?? "")
        }
        XCTAssertNil(build(model).badge, "an explicit needs queue is authoritative over old groups")
    }

    func testFailingJobsBadgeWinsOverWaitingAndFallsBackToWaiting() throws {
        // Arrange
        var model = try fixture("jobs")
        // Act / Assert
        XCTAssertEqual(build(model).badge, Badge("2", .warn))
        model.removeValue(forKey: "counts")
        XCTAssertEqual(build(model).badge, Badge("2", .warn), "derive failures if the new count is missing")
        model.removeValue(forKey: "jobs")
        XCTAssertEqual(build(model).badge, Badge("1", .warn))
        model["needs"] = []
        XCTAssertNil(build(model).badge)
    }

    func testJobsAreGroupedByHostWithFailuresFirstAndStatusActions() throws {
        // Arrange / Act
        let result = build(try fixture("jobs"))
        let jobs = try XCTUnwrap(result.nodes.first { $0.title == "Jobs" })
        let local = try XCTUnwrap(jobs.children.first { $0.title == "local" })
        let remote = try XCTUnwrap(jobs.children.first { $0.title == "server1" })
        // Assert
        XCTAssertEqual(jobs.children.map(\.title), ["laptop", "local", "server1"])
        XCTAssertEqual(local.children.map(\.title), ["!  job-b — failing · exit 2", "●  job-a — idle · exit 0", "●  job-c — running"])
        XCTAssertEqual(local.children.first?.toolTip, "Check failure")
        XCTAssertTrue(remote.children[0].title.contains("Connection timed out"))
        XCTAssertTrue(remote.children[0].title.contains("last seen"))
        XCTAssertEqual(jobs.children[0].children[0].title, "No jobs")
        guard case .run(let localCommand) = local.children[0].action,
              case .run(let remoteCommand) = remote.children[1].action else { return XCTFail("Jobs should use run actions") }
        XCTAssertEqual(localCommand.first, "/usr/bin/osascript")
        XCTAssertTrue(localCommand[2].contains("tell application \"Terminal\""))
        XCTAssertTrue(localCommand.last?.hasSuffix("'loom' 'jobs' 'status' 'job-b'") == true)
        XCTAssertTrue(remoteCommand.last?.hasSuffix("'loom' '--host' 'server1' 'jobs' 'status' 'job-d'") == true)
    }

    func testJobStatusShellArgumentsCannotExecuteEmbeddedCode() throws {
        // Arrange: capture shell arguments without launching Terminal or loom.
        let name = "job-a ' \" $(exit 42); `exit 43`\nnext"
        let host = "server1 ' $(exit 44)"
        let command = try XCTUnwrap(AgentsMenu.jobStatusCommand(name: name, host: host).last)
        let capture = "loom() { printf '%s\\0' \"$@\"; }; " + command
        // Act
        let result = Shell.run(["/bin/sh", "-c", capture])
        let arguments = result.output.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        // Assert
        XCTAssertTrue(result.ok, result.summary)
        XCTAssertEqual(arguments, ["--host", host, "jobs", "status", name, ""])
    }

    func testJobNeedsWithoutSnapshotAreStillVisible() throws {
        // Arrange
        var model = try fixture("fleet")
        model.removeValue(forKey: "jobs")
        model.removeValue(forKey: "counts")
        model["needs"] = (model["needs"] as? [[String: Any]])?.filter { $0["kind"] as? String == "job" }
        // Act
        let jobs = try XCTUnwrap(build(model).nodes.first { $0.title == "Jobs" })
        // Assert
        XCTAssertEqual(jobs.children[0].title, "server1")
        XCTAssertEqual(jobs.children[0].children[0].title, "!  job-a — failing")
        XCTAssertNotNil(jobs.children[0].children[0].action)
        XCTAssertEqual(build(model).badge, Badge("1", .warn))
    }

    func testLaterShowsOnlyNext24HoursSortedWithRelativeTimes() throws {
        // Arrange / Act
        let result = build(try fixture("later"))
        let later = try XCTUnwrap(result.nodes.first { $0.title == "Later" })
        // Assert
        XCTAssertEqual(later.children.map(\.title), ["Due now — in 0s", "Wake session-a [laptop] — in 12m",
                                                   "ISO time — in 30m", "Next day [server1] — in 1d"])
        XCTAssertTrue(later.children.allSatisfy { $0.action == nil })
        XCTAssertTrue(later.children[1].toolTip?.contains("session-a") == true)
        XCTAssertNil(result.badge)
    }

    func testLegacyJSONPreservesOriginalMenuAndBadgeWithEveryNewKeyAbsent() throws {
        // Arrange / Act
        let result = build(try fixture("legacy"))
        // Assert
        XCTAssertEqual(result.badge, Badge("1", .alert))
        XCTAssertEqual(MenuDump.lines(result.nodes), [
            "· Agents — 1 blocked · 1 waiting · 1 working",
            "· Blocked on you",
            "!  session-a · needs you 1m — Permission prompt    [run quietly: \(atc) --jump session-a]",
            "· Waiting on you",
            "◆  session-b · waiting 2h — Ready for review    [run quietly: \(atc) --jump session-b]",
            "· Working",
            "●  session-c — Running checks    [run quietly: \(atc) --jump session-c]",
            "Open atc…    [run: \(atc) --open]"
        ])
    }

    func testAbsentNullAndEmptyNewKeysDoNotCreateEmptySubmenus() {
        // Arrange
        let models: [[String: Any]] = [[:], ["needs": NSNull(), "counts": NSNull(), "later": NSNull(), "jobs": NSNull()],
                                     ["needs": [], "counts": [:], "later": [], "jobs": [:]]]
        for model in models {
            // Act
            let result = build(model)
            // Assert
            XCTAssertNil(result.badge)
            XCTAssertEqual(result.nodes.map(\.title), ["Agents — 0 waiting · 0 working", "Open atc…"])
        }
    }

    func testRemoteSessionDoesNotUseLocalTtyFastPath() throws {
        // Arrange / Act
        let lines = MenuDump.lines(build(try fixture("fleet")).nodes)
        // Assert
        XCTAssertTrue(lines.contains("!  session-a [server1] · needs you 1m — Permission prompt    [run quietly: \(atc) --jump session-a]"))
    }

    func testPollingRetainsRemoteNeedsAndJobsUntilNextFullRefresh() throws {
        // Arrange: a fake atc exercises process -> JSON -> cached model -> menu and badge.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("roost-needs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let full = directory.appendingPathComponent("full.json")
        let local = directory.appendingPathComponent("local.json")
        let executable = directory.appendingPathComponent("atc")
        try JSONSerialization.data(withJSONObject: fixture("fleet")).write(to: full)
        let localModel: [String: Any] = ["groups": [:], "hosts": [], "needs": [], "later": [], "jobs": [:],
                                       "counts": ["needs": 0, "needs_urgent": 0, "jobs_failing": 0]]
        try JSONSerialization.data(withJSONObject: localModel).write(to: local)
        try """
        #!/bin/sh
        cd -- "$(dirname -- "$0")"
        case "$*" in
          *--no-hosts*) exec /bin/cat local.json ;;
          *) exec /bin/cat full.json ;;
        esac
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let module = AgentsModule(atc: executable.path, webURL: webURL)
        module.providersInterval = .infinity
        // Act / Assert
        module.refreshNow()
        let fullLines = MenuDump.lines(module.menu())
        XCTAssertEqual(module.badge, Badge("1", .alert))
        for _ in 0..<2 {
            module.refreshNow()
            XCTAssertEqual(MenuDump.lines(module.menu()), fullLines)
            XCTAssertEqual(module.badge, Badge("1", .alert), "fast polls must neither lose nor duplicate remote needs")
        }
        try JSONSerialization.data(withJSONObject: localModel).write(to: full)
        module.hostsInterval = 0
        module.refreshNow()
        XCTAssertNil(module.badge)
        XCTAssertFalse(module.menu().contains { ["Needs you", "Jobs", "Later"].contains($0.title) })
        XCTAssertTrue(module.menu().contains { $0.title == "Open atc web" })
    }

    func testFastPollKeepsFreshLoomHostsInsteadOfRestoringOldFailures() throws {
        // Arrange
        let previous = try fixture("fleet")
        let fresh: [String: Any] = ["needs": [], "jobs": ["server1": ["ok": true, "jobs": []]],
                                   "counts": ["needs_urgent": 0, "jobs_failing": 0]]
        // Act
        let merged = AgentsModule.preservingRemoteData(in: fresh, from: previous)
        // Assert
        let jobs = try XCTUnwrap(merged["jobs"] as? [String: [String: Any]])
        XCTAssertEqual((jobs["server1"]?["jobs"] as? [[String: Any]])?.count, 0)
        XCTAssertEqual((merged["counts"] as? [String: Any])?["jobs_failing"] as? Int, 0)
        let menu = try XCTUnwrap(build(merged).nodes.first { $0.title == "Jobs" })
        XCTAssertEqual(menu.children[0].children[0].title, "No jobs", "stale job needs must not restore fresh jobs")
    }

    func testWebURLComesFromEnvironmentThenFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("web-url").path
        XCTAssertNil(AgentsModule.configuredWebURL(environment: [:], file: file))
        try "https://atc.example.com:7443\n".write(toFile: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(AgentsModule.configuredWebURL(environment: [:], file: file), "https://atc.example.com:7443")
        XCTAssertEqual(AgentsModule.configuredWebURL(environment: ["ATC_WEB_URL": "https://env.example.com"], file: file),
                       "https://env.example.com")
        try "not a url\n".write(toFile: file, atomically: true, encoding: .utf8)
        XCTAssertNil(AgentsModule.configuredWebURL(environment: [:], file: file))
    }
}
