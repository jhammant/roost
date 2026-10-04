import XCTest
@testable import RoostCore

final class AgentsMenuTests: XCTestCase {
    private let atc = "/usr/local/bin/atc"

    private func fixture() -> [String: Any] {
        [
            "groups": [
                "blocked": [["name": "steer-06", "sid": "s-1", "doing": "permission prompt: Bash  touch x",
                             "state": "needs you 1m"]],
                "waiting": [["name": "docs-site", "sid": "s-2", "doing": "“Five PRs are open”\nsecond line",
                             "state": "waiting 2h"]],
                "working": [["name": "web-app", "sid": "s-3", "doing": "Bash  Run the playtest"]],
                "parked": [["name": "old"], ["name": "older"]],
                "background": [], "other": [],
            ],
            "agents": [["tool": "codex", "etime": "5-08:57:52", "command": "codex exec fix"]],
            "hosts": [
                ["host": "buildbox", "ok": true, "counts": ["live": 0],
                 "agents": [["tool": "codex", "etime": "09:44:14", "command": "codex"],
                            ["tool": "codex", "etime": "5-08:57:52", "command": "codex"]]],
                ["host": "devbox", "ok": false, "error": "ssh: connect timed out\nmore"],
            ],
            "quota": ["session": ["percentUsed": 10], "weekly": ["effectivePercent": 77],
                      "headroom": "comfortable", "override": NSNull(), "advice": ["parallelism": 4]],
        ]
    }

    func testBlockedSessionsBadgeRedAndJumpThroughAtc() {
        let (nodes, badge) = AgentsMenu.build(model: fixture(), error: nil, providers: [], atc: atc)
        XCTAssertEqual(badge, Badge("1", .alert))
        let lines = MenuDump.lines(nodes)
        XCTAssertEqual(lines.first, "· Agents — 1 blocked · 1 waiting · 1 working")
        XCTAssertTrue(lines.contains("!  steer-06 · needs you 1m — permission prompt: Bash  touch x    [run quietly: \(atc) --jump s-1]"),
                      lines.joined(separator: "\n"))
        XCTAssertTrue(lines.contains("◆  docs-site · waiting 2h — “Five PRs are open”    [run quietly: \(atc) --jump s-2]"),
                      "first line only, with how long it has waited")
        XCTAssertTrue(lines.contains("●  web-app — Bash  Run the playtest    [run quietly: \(atc) --jump s-3]"),
                      "no state given: no age shown")
        XCTAssertTrue(lines.contains("·      2 parked"))
    }

    func testWaitingOnlyBadgesOrange() {
        var model = fixture()
        var groups = model["groups"] as! [String: Any]
        groups["blocked"] = []
        model["groups"] = groups
        XCTAssertEqual(AgentsMenu.build(model: model, error: nil, providers: [], atc: atc).badge, Badge("1", .warn))
    }

    func testServersShowAgentsStaleAndErrors() {
        let lines = MenuDump.lines(AgentsMenu.build(model: fixture(), error: nil, providers: [], atc: atc).nodes)
        XCTAssertTrue(lines.contains("buildbox: 2 agents, 1 stale  ▸"))
        XCTAssertTrue(lines.contains("· devbox: ssh: connect timed out"))
        XCTAssertTrue(lines.contains { $0.contains("codex  up 5d  stale?  codex exec fix") })
    }

    func testQuotaLineAndSwarmCap() {
        let providers: [[String: Any]] = [
            ["id": "codex", "label": "Codex (ChatGPT pro)", "ok": true, "limits": [["label": "weekly", "percent": 19]]],
            ["id": "kimi", "label": "Kimi Code", "ok": true,
             "limits": [["label": "5h window", "percent": 1], ["label": "weekly", "percent": 12]]],
            ["id": "deepseek", "label": "DeepSeek", "ok": true, "limits": [], "balanceUsd": 11.42],
            ["id": "gemini", "label": "Gemini", "ok": false, "limits": [["label": "daily", "percent": 3]]],
        ]
        let lines = MenuDump.lines(AgentsMenu.build(model: fixture(), error: nil, providers: providers, atc: atc).nodes)
        XCTAssertTrue(lines.contains(
            "· Quota: Claude 5h 10% · week 77%   Codex weekly 19%   Kimi 5h 1% · weekly 12%   DeepSeek $11.42"))
        XCTAssertTrue(lines.contains("Swarm cap: ≤4 comfortable (auto)  ▸"))
        XCTAssertTrue(lines.contains("    Raise    [run: \(atc) --cap up]"))
    }

    func testNoModelYetOffersToOpenAtc() {
        let (nodes, badge) = AgentsMenu.build(model: nil, error: "atc not found", providers: [], atc: atc)
        XCTAssertNil(badge)
        XCTAssertEqual(MenuDump.lines(nodes), ["· Agents", "· atc: atc not found", "Open atc…    [run: \(atc) --open]"])
    }

    func testEtime() {
        XCTAssertEqual(AgentsMenu.etimeSeconds("05:03"), 303)
        XCTAssertEqual(AgentsMenu.etimeSeconds("1:02:03"), 3723)
        XCTAssertEqual(AgentsMenu.etimeSeconds("13-19:04:11"), 13 * 86_400 + 19 * 3600 + 4 * 60 + 11)
    }
}

final class ScriptMenuTests: XCTestCase {
    func testParsesNestedItemsActionsAndBadge() {
        let json = """
        {"title": "Servers", "badge": {"text": "2", "level": "alert"},
         "items": [{"title": "buildbox ok", "open": "https://buildbox.local"},
                   {"title": "Restart", "run": "echo hi"},
                   {"title": "Argv", "run": ["/bin/echo", "x"]},
                   {"title": "Info line"},
                   {"title": "More", "items": [{"title": "Deep", "run": "true"}]}]}
        """
        let result = ScriptMenu.parse(Data(json.utf8), fallbackTitle: "servers")
        XCTAssertEqual(result.badge, Badge("2", .alert))
        XCTAssertEqual(MenuDump.lines([result.node]), [
            "Servers  (2)  ▸",
            "    buildbox ok    [open: https://buildbox.local]",
            "    Restart    [run: /bin/sh -c echo hi]",
            "    Argv    [run: /bin/echo x]",
            "    · Info line",
            "    More  ▸",
            "        Deep    [run: /bin/sh -c true]",
        ])
    }

    func testBadJSONBecomesAnErrorEntry() {
        let result = ScriptMenu.parse(Data("not json".utf8), fallbackTitle: "broken")
        XCTAssertNil(result.badge)
        XCTAssertEqual(MenuDump.lines([result.node]), ["broken  ⚠︎  ▸", "    · error: didn't print a JSON object"])
    }

    func testModuleRunsExecutablesInItsFolder() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("roost-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let good = dir.appendingPathComponent("a-good.sh")
        try "#!/bin/sh\necho '{\"title\": \"Good\", \"badge\": \"1\", \"items\": [{\"title\": \"x\"}]}'\n"
            .write(to: good, atomically: true, encoding: .utf8)
        let failing = dir.appendingPathComponent("b-failing.sh")
        try "#!/bin/sh\necho boom >&2\nexit 3\n".write(to: failing, atomically: true, encoding: .utf8)
        let notExecutable = dir.appendingPathComponent("c-readme.txt")
        try "ignored".write(to: notExecutable, atomically: true, encoding: .utf8)
        for file in [good, failing] {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }

        let module = ScriptsModule(directory: dir)
        module.refreshNow()
        XCTAssertEqual(module.menu().map(\.title), ["Good  (1)", "b-failing  ⚠︎"])
        XCTAssertEqual(module.menu()[1].children.first?.title, "error: boom")
        XCTAssertEqual(module.badge, Badge("1", .info))
    }
}

final class BadgeAndComposeTests: XCTestCase {
    func testMostUrgentWins() {
        XCTAssertEqual(Badge.mostUrgent([Badge("p", .info), nil, Badge("3", .warn), Badge("1", .alert)]), Badge("1", .alert))
        XCTAssertNil(Badge.mostUrgent([nil, nil]))
    }

    func testShellFindsToolsOnTheWiderPath() {
        XCTAssertNotNil(Shell.which("sh"))
        let result = Shell.run(["/bin/sh", "-c", "echo $PATH"])
        XCTAssertTrue(result.ok)
        XCTAssertTrue(result.output.contains("/opt/homebrew/bin"))
        XCTAssertEqual(Shell.run(["definitely-not-a-command-xyz"]).summary, "definitely-not-a-command-xyz not found")
    }
}
