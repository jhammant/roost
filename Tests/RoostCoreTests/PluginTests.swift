import XCTest
@testable import RoostCore

/// A throwaway plugins folder.
private final class Sandbox {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("roost-plugins-\(UUID().uuidString)")
    var plugins: URL { root.appendingPathComponent("plugins") }
    var settings: URL { root.appendingPathComponent("settings.json") }

    init() throws {
        try FileManager.default.createDirectory(at: plugins, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    /// A plugin folder with a manifest and an executable `plugin.sh`.
    @discardableResult
    func plugin(_ folder: String, manifest: String, script: String? = nil, in parent: URL? = nil) throws -> URL {
        let dir = (parent ?? plugins).appendingPathComponent(folder)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try manifest.write(to: dir.appendingPathComponent("plugin.json"), atomically: true, encoding: .utf8)
        if let script {
            let file = dir.appendingPathComponent("plugin.sh")
            try ("#!/bin/sh\n" + script).write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        return dir
    }
}

/// A built-in stand-in that records what the registry does to it.
private final class FakeModule: RoostModule {
    let id: String
    var started = 0, stopped = 0
    init(_ id: String) { self.id = id }
    var badge: Badge? { nil }
    func start(onChange: @escaping () -> Void) { started += 1 }
    func stop() { stopped += 1 }
    func refreshNow() {}
    func menu() -> [MenuNode] { [.header(id)] }
}

final class PluginManifestTests: XCTestCase {
    func testDefaultsAndTildeExpansion() throws {
        let manifest = try PluginManifest.parse(["command": "echo {}", "env": ["CONFIG": "~/x.yaml"]], folderName: "hello")
        XCTAssertEqual(manifest.id, "hello", "the folder name is the id when none is given")
        XCTAssertEqual(manifest.name, "hello")
        XCTAssertEqual(manifest.command, ["/bin/sh", "-c", "echo {}"])
        XCTAssertEqual(manifest.interval, 30)
        XCTAssertEqual(manifest.timeout, 10)
        XCTAssertEqual(manifest.environment["CONFIG"], NSHomeDirectory() + "/x.yaml")
    }

    func testFullManifest() throws {
        let manifest = try PluginManifest.parse([
            "id": "mail-sync", "name": "Mail sync", "version": "0.2.0", "description": "Review queue",
            "command": ["./plugin.py", "--json"], "interval": 300, "timeout": 20.5, "requires": ["python3"],
        ], folderName: "ignored")
        XCTAssertEqual(manifest.id, "mail-sync")
        XCTAssertEqual(manifest.command, ["./plugin.py", "--json"])
        XCTAssertEqual(manifest.interval, 300)
        XCTAssertEqual(manifest.timeout, 20.5)
        XCTAssertEqual(manifest.requires, ["python3"])
    }

    func testErrorsSayWhatToFix() {
        func error(_ object: [String: Any]) -> String? {
            do { _ = try PluginManifest.parse(object, folderName: "x"); return nil } catch { return "\(error)" }
        }
        XCTAssertEqual(error([:]), "\"command\" must be a string or a non-empty array of strings")
        XCTAssertEqual(error(["command": []]), "\"command\" must be a string or a non-empty array of strings")
        XCTAssertEqual(error(["command": "x", "id": "Bad ID"]), "id \"Bad ID\" must be lowercase letters, digits, '.', '_' or '-'")
        XCTAssertEqual(error(["command": "x", "interval": 1]), "\"interval\" must be a number of seconds from 5 to 86400")
        XCTAssertEqual(error(["command": "x", "timeout": "soon"]), "\"timeout\" must be a number of seconds from 1 to 300")
        XCTAssertEqual(error(["command": "x", "env": ["N": 1]]), "\"env\" must map names to strings")
        XCTAssertEqual(error(["command": "x", "requires": "python3"]), "\"requires\" must be a list of command names")
    }
}

final class PluginModuleTests: XCTestCase {
    func testRunsInItsFolderWithItsEnvironmentAndActionsInherit() throws {
        let sandbox = try Sandbox()
        let dir = try sandbox.plugin("greeter", manifest: """
            {"id": "greeter", "name": "Greeter", "command": ["./plugin.sh"], "env": {"WHO": "world"}}
            """, script: """
            cat <<JSON
            {"title": "Hello $WHO", "badge": {"text": "2", "level": "warn"},
             "items": [{"title": "from $(basename "$PWD") as $ROOST_PLUGIN_ID"},
                       {"title": "Approve", "run": ["./plugin.sh", "approve", "7"], "confirm": "Approve item 7?"},
                       {"title": "Shell", "run": "echo hi"}]}
            JSON
            """)
        let manifest = try PluginManifest.load(from: dir)
        let plugin = PluginModule(manifest: manifest, directory: dir)
        XCTAssertEqual(MenuDump.lines(plugin.menu()), ["Greeter  ▸", "    · Loading…"], "before the first run")

        plugin.refreshNow()
        XCTAssertEqual(plugin.badge, Badge("2", .warn))
        XCTAssertEqual(MenuDump.lines(plugin.menu()), [
            "Hello world  (2)  ▸",
            "    · from greeter as greeter",
            "    Approve    [run: ./plugin.sh approve 7]  [confirm: Approve item 7?]",
            "    Shell    [run: /bin/sh -c echo hi]",
        ])
        // The action carries the plugin's folder and environment, so it runs where the refresh ran.
        guard case .command(let command)? = plugin.menu()[0].children[1].action else {
            return XCTFail("a plugin's run item should be a plugin command")
        }
        XCTAssertEqual(command.directory, dir)
        XCTAssertEqual(command.environment["WHO"], "world")
        XCTAssertEqual(command.environment["ROOST_PLUGIN_DIR"], dir.path)
        let ran = Shell.run(["./plugin.sh"], extraEnvironment: command.environment, directory: command.directory)
        XCTAssertTrue(ran.ok, ran.summary)
    }

    func testFailuresAndMissingToolsShowInsteadOfBreakingTheMenu() throws {
        let sandbox = try Sandbox()
        let failing = try sandbox.plugin("failing", manifest: #"{"command": ["./plugin.sh"]}"#, script: "echo boom >&2\nexit 4\n")
        let plugin = PluginModule(manifest: try PluginManifest.load(from: failing), directory: failing)
        plugin.refreshNow()
        XCTAssertEqual(MenuDump.lines(plugin.menu()), ["failing  ⚠︎  ▸", "    · error: boom"])
        XCTAssertNil(plugin.badge)

        let needy = try sandbox.plugin("needy", manifest: #"{"command": "true", "requires": ["no-such-tool-xyz"]}"#)
        let waiting = PluginModule(manifest: try PluginManifest.load(from: needy), directory: needy)
        waiting.refreshNow()
        XCTAssertEqual(MenuDump.lines(waiting.menu()), ["needy  ⚠︎  ▸", "    · error: needs no-such-tool-xyz on the PATH"])

        let slow = try sandbox.plugin("slow", manifest: #"{"command": ["./plugin.sh"], "timeout": 1}"#, script: "sleep 5\n")
        let timing = PluginModule(manifest: try PluginManifest.load(from: slow), directory: slow)
        timing.refreshNow()
        XCTAssertTrue(MenuDump.lines(timing.menu())[1].contains("timed out after 1s"), MenuDump.lines(timing.menu()).joined(separator: "\n"))
    }

    func testConfirmIsDroppedFromItemsThatDoNothing() {
        let result = ScriptMenu.parse(Data(#"{"items": [{"title": "Note", "confirm": "Really?"}]}"#.utf8), fallbackTitle: "x")
        XCTAssertNil(result.node.children[0].confirmation)
    }
}

final class ModuleRegistryTests: XCTestCase {
    func testDiscoversPluginsBetweenBuiltInsAndReportsBrokenOnes() throws {
        let sandbox = try Sandbox()
        try sandbox.plugin("b-good", manifest: #"{"id": "good", "name": "Good", "version": "1.0", "command": "true"}"#)
        try sandbox.plugin("a-broken", manifest: "{not json")
        try sandbox.plugin("c-clash", manifest: #"{"id": "agents", "command": "true"}"#)
        try FileManager.default.createDirectory(at: sandbox.plugins.appendingPathComponent("d-empty"), withIntermediateDirectories: true)
        // A symlinked folder (how `--install-plugin` installs) counts too.
        let elsewhere = try sandbox.plugin("linked", manifest: #"{"command": "true"}"#, in: sandbox.root)
        try FileManager.default.createSymbolicLink(at: sandbox.plugins.appendingPathComponent("e-linked"), withDestinationURL: elsewhere)

        let registry = ModuleRegistry(leading: [FakeModule("agents")], trailing: [FakeModule("scripts")],
                                      pluginsDirectory: sandbox.plugins, settingsFile: sandbox.settings)
        XCTAssertEqual(registry.all.map(\.id), ["agents", "good", "linked", "scripts"])
        XCTAssertEqual(registry.problems.map(\.name), ["a-broken", "c-clash", "d-empty"])
        XCTAssertEqual(registry.problems.map(\.reason), ["plugin.json isn't a JSON object", "id \"agents\" is already taken", "no plugin.json"])

        let menu = MenuDump.lines([registry.pluginsMenu(toggle: { _, _ in }, openFolder: {}, reload: {})])
        XCTAssertEqual(menu[0], "Plugins (2)  ▸")
        XCTAssertTrue(menu.contains("    ✓ Agents  (built in)    [action]"))
        XCTAssertTrue(menu.contains("    ✓ Good  1.0    [action]"))
        XCTAssertTrue(menu.contains("    · a-broken  ⚠︎  plugin.json isn't a JSON object"))
    }

    func testSwitchingOffStopsAndPersistsAndSwitchingOnStarts() throws {
        let sandbox = try Sandbox()
        let agents = FakeModule("agents")
        let registry = ModuleRegistry(leading: [agents], pluginsDirectory: sandbox.plugins, settingsFile: sandbox.settings)
        var changes = 0
        registry.start { changes += 1 }
        XCTAssertEqual(agents.started, 1)

        try registry.setEnabled("agents", false)
        XCTAssertEqual(agents.stopped, 1)
        XCTAssertTrue(registry.active.isEmpty)
        XCTAssertEqual(RoostSettings.load(from: sandbox.settings).disabled, ["agents"], "saved for next launch")
        XCTAssertEqual(ModuleRegistry(leading: [FakeModule("agents")], pluginsDirectory: sandbox.plugins,
                                      settingsFile: sandbox.settings).active.count, 0)

        try registry.setEnabled("agents", true)
        XCTAssertEqual(agents.started, 2)
        XCTAssertEqual(registry.active.map(\.id), ["agents"])
        XCTAssertEqual(changes, 2)
    }

    func testReloadKeepsUnchangedPluginsAndPicksUpNewOnes() throws {
        let sandbox = try Sandbox()
        try sandbox.plugin("one", manifest: #"{"command": "true"}"#)
        let registry = ModuleRegistry(leading: [], pluginsDirectory: sandbox.plugins, settingsFile: sandbox.settings)
        let first = try XCTUnwrap(registry.plugins.first)

        try sandbox.plugin("two", manifest: #"{"command": "true"}"#)
        registry.reload()
        XCTAssertEqual(registry.plugins.map(\.id), ["one", "two"])
        XCTAssertTrue(registry.plugins[0] === first, "an unchanged plugin keeps running as it was")

        try FileManager.default.removeItem(at: sandbox.plugins.appendingPathComponent("one"))
        registry.reload()
        XCTAssertEqual(registry.plugins.map(\.id), ["two"])
    }
}
