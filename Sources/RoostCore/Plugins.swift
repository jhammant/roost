import Foundation

/// Roost plugins: a folder with a `plugin.json` in ~/.config/roost/plugins. The folder
/// can be a symlink, so a tool can ship its own plugin in its repo:
///
///     {"id": "mail-sync", "name": "Mail sync", "command": ["./roost-plugin.py"],
///      "interval": 300, "timeout": 20, "env": {"CONFIG": "~/.config/mail-sync.yaml"},
///      "requires": ["mail-sync"]}
///
/// The command prints the same JSON as a script module. Unlike a script module it gets
/// its own schedule, timeout and environment, runs in its own folder, and its `run`
/// items run there too, so a plugin can call itself back (`["./roost-plugin.py", "approve", "42"]`).
public struct PluginManifest: Equatable {
    public var id: String
    public var name: String
    public var description: String
    public var version: String
    public var command: [String]
    public var interval: TimeInterval
    public var timeout: TimeInterval
    public var environment: [String: String]
    public var requires: [String]

    public static let fileName = "plugin.json"
    public static let defaultInterval: TimeInterval = 30
    public static let defaultTimeout: TimeInterval = 10

    /// Reads and checks `plugin.json`, with an error that says what to fix.
    public static func load(from directory: URL) throws -> PluginManifest {
        let file = directory.appendingPathComponent(fileName)
        guard let data = FileManager.default.contents(atPath: file.path) else {
            throw PluginError("no \(fileName)")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw PluginError("\(fileName) isn't a JSON object")
        }
        return try parse(object, folderName: directory.lastPathComponent)
    }

    public static func parse(_ object: [String: Any], folderName: String) throws -> PluginManifest {
        let id = object["id"] as? String ?? folderName
        guard id.range(of: "^[a-z0-9][a-z0-9._-]*$", options: .regularExpression) != nil else {
            throw PluginError("id \"\(id)\" must be lowercase letters, digits, '.', '_' or '-'")
        }
        let command: [String]
        if let line = object["command"] as? String, !line.isEmpty {
            command = ["/bin/sh", "-c", line]
        } else if let argv = object["command"] as? [String], !argv.isEmpty, !argv[0].isEmpty {
            command = argv
        } else {
            throw PluginError("\"command\" must be a string or a non-empty array of strings")
        }
        func seconds(_ key: String, _ fallback: TimeInterval, _ range: ClosedRange<TimeInterval>) throws -> TimeInterval {
            guard let value = object[key] else { return fallback }
            guard let number = (value as? Int).map(Double.init) ?? (value as? Double), range.contains(number) else {
                throw PluginError("\"\(key)\" must be a number of seconds from \(Int(range.lowerBound)) to \(Int(range.upperBound))")
            }
            return number
        }
        let environment = object["env"] ?? [String: String]()
        guard let env = environment as? [String: String] else {
            throw PluginError("\"env\" must map names to strings")
        }
        let requires = object["requires"] ?? [String]()
        guard let tools = requires as? [String] else {
            throw PluginError("\"requires\" must be a list of command names")
        }
        return PluginManifest(
            id: id,
            name: (object["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id,
            description: object["description"] as? String ?? "",
            version: object["version"] as? String ?? "",
            command: command,
            interval: try seconds("interval", defaultInterval, 5...86_400),
            timeout: try seconds("timeout", defaultTimeout, 1...300),
            // Only a leading ~ is expanded: expandingTildeInPath also squashes "https://" to "https:/".
            environment: env.mapValues { $0.hasPrefix("~") ? ($0 as NSString).expandingTildeInPath : $0 },
            requires: tools)
    }
}

public struct PluginError: Error, CustomStringConvertible, Equatable {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// One folder in the plugins directory, loaded or not.
public struct DiscoveredPlugin {
    public let directory: URL
    public let manifest: Result<PluginManifest, PluginError>
    /// When plugin.json last changed, so a reload only restarts plugins that changed.
    public let modified: Date?
}

public enum PluginDiscovery {
    /// ~/.config/roost, or ROOST_CONFIG_DIR.
    public static var configDirectory: URL {
        if let custom = ProcessInfo.processInfo.environment["ROOST_CONFIG_DIR"], !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config/roost", isDirectory: true)
    }

    /// ~/.config/roost/plugins, or ROOST_PLUGINS_DIR.
    public static var defaultDirectory: URL {
        if let custom = ProcessInfo.processInfo.environment["ROOST_PLUGINS_DIR"], !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
        }
        return configDirectory.appendingPathComponent("plugins", isDirectory: true)
    }

    /// Every visible folder (or symlink to one) in `directory`, sorted by name.
    public static func scan(_ directory: URL) -> [DiscoveredPlugin] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.sorted().filter { !$0.hasPrefix(".") }.compactMap { name in
            let folder = directory.appendingPathComponent(name).resolvingSymlinksInPath()
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                return nil
            }
            let file = folder.appendingPathComponent(PluginManifest.fileName)
            let modified = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
            let manifest = Result { try PluginManifest.load(from: folder) }.mapError { $0 as? PluginError ?? PluginError("\($0)") }
            return DiscoveredPlugin(directory: folder, manifest: manifest, modified: modified)
        }
    }
}

/// A plugin as a Roost module: runs its command on its own schedule.
public final class PluginModule: RoostModule {
    public let manifest: PluginManifest
    public let directory: URL
    public let modified: Date?
    public var id: String { manifest.id }
    public var name: String { manifest.name }

    private let queue: DispatchQueue
    private let lock = NSLock()
    private var result: ScriptResult?
    private var running = false
    private let wake = DispatchSemaphore(value: 0)

    public init(manifest: PluginManifest, directory: URL, modified: Date? = nil) {
        self.manifest = manifest
        self.directory = directory
        self.modified = modified
        queue = DispatchQueue(label: "io.hammant.roost.plugin.\(manifest.id)", qos: .utility)
    }

    /// What every command of this plugin runs with: its folder, its env, and who it is.
    public var context: MenuNode.Command {
        var environment = manifest.environment
        environment["ROOST_PLUGIN_ID"] = manifest.id
        environment["ROOST_PLUGIN_DIR"] = directory.path
        return MenuNode.Command(manifest.command, directory: directory, environment: environment)
    }

    public var badge: Badge? {
        lock.lock()
        defer { lock.unlock() }
        return result?.badge
    }

    public func menu() -> [MenuNode] {
        lock.lock()
        defer { lock.unlock() }
        return [result?.node ?? MenuNode(name, children: [.header("Loading…")])]
    }

    public func refreshNow() {
        let fresh: ScriptResult
        let missing = manifest.requires.filter { Shell.which($0) == nil }
        if !missing.isEmpty {
            fresh = ScriptMenu.failure(title: name, reason: "needs \(missing.joined(separator: ", ")) on the PATH")
        } else {
            let context = self.context
            let output = Shell.run(context.argv, timeout: manifest.timeout,
                                   extraEnvironment: context.environment, directory: directory)
            fresh = output.ok ? ScriptMenu.parse(output.stdout, fallbackTitle: name, context: context)
                              : ScriptMenu.failure(title: name, reason: output.summary)
        }
        lock.lock()
        result = fresh
        lock.unlock()
    }

    public func start(onChange: @escaping () -> Void) {
        guard !running else { return }
        running = true
        queue.async { [weak self] in
            while let self = self, self.running {
                autoreleasepool { self.refreshNow() }  // see AgentsModule.start
                DispatchQueue.main.async(execute: onChange)
                _ = self.wake.wait(timeout: .now() + self.manifest.interval)
            }
        }
    }

    public func stop() {
        running = false
        wake.signal()
    }

    public func poke() {
        wake.signal()
    }
}

/// What the user switched off, in ~/.config/roost/settings.json, so it is easy to read and script.
public struct RoostSettings: Equatable {
    public var disabled: Set<String> = []

    public init(disabled: Set<String> = []) {
        self.disabled = disabled
    }

    public static var defaultFile: URL {
        PluginDiscovery.configDirectory.appendingPathComponent("settings.json")
    }

    public static func load(from file: URL) -> RoostSettings {
        guard let data = FileManager.default.contents(atPath: file.path),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return RoostSettings()
        }
        return RoostSettings(disabled: Set(object["disabled"] as? [String] ?? []))
    }

    public func save(to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: ["disabled": disabled.sorted()],
                                              options: [.prettyPrinted, .sortedKeys])
        try data.write(to: file, options: .atomic)
    }
}

/// Every module Roost knows: the built-in ones and the installed plugins, each of
/// which can be switched off. Plugins sit between `leading` and `trailing` built-ins.
public final class ModuleRegistry {
    public let leading: [RoostModule]
    public let trailing: [RoostModule]
    public let pluginsDirectory: URL
    public let settingsFile: URL
    public private(set) var plugins: [PluginModule] = []
    /// Plugin folders that couldn't be loaded, with why.
    public private(set) var problems: [(name: String, reason: String)] = []
    public private(set) var settings: RoostSettings

    private var onChange: (() -> Void)?

    public init(leading: [RoostModule], trailing: [RoostModule] = [],
                pluginsDirectory: URL = PluginDiscovery.defaultDirectory,
                settingsFile: URL = RoostSettings.defaultFile) {
        self.leading = leading
        self.trailing = trailing
        self.pluginsDirectory = pluginsDirectory
        self.settingsFile = settingsFile
        settings = RoostSettings.load(from: settingsFile)
        reload()
    }

    public var all: [RoostModule] { leading + plugins + trailing }
    public var active: [RoostModule] { all.filter { isEnabled($0.id) } }

    public func isEnabled(_ id: String) -> Bool { !settings.disabled.contains(id) }

    /// Re-reads the plugins folder. Unchanged plugins keep running; new ones start,
    /// removed or edited ones stop (an edited one starts again from its new manifest).
    public func reload() {
        let builtIn = Set((leading + trailing).map(\.id))
        var kept: [PluginModule] = []
        var seen = Set<String>()
        problems = []
        for found in PluginDiscovery.scan(pluginsDirectory) {
            let folder = found.directory.lastPathComponent
            switch found.manifest {
            case .failure(let error):
                problems.append((folder, error.description))
            case .success(let manifest):
                if builtIn.contains(manifest.id) || seen.contains(manifest.id) {
                    problems.append((folder, "id \"\(manifest.id)\" is already taken"))
                    continue
                }
                seen.insert(manifest.id)
                if let existing = plugins.first(where: { $0.id == manifest.id }),
                   existing.manifest == manifest, existing.directory == found.directory, existing.modified == found.modified {
                    kept.append(existing)
                } else {
                    kept.append(PluginModule(manifest: manifest, directory: found.directory, modified: found.modified))
                }
            }
        }
        let keptIDs = Set(kept.map(ObjectIdentifier.init))
        for old in plugins where !keptIDs.contains(ObjectIdentifier(old)) { old.stop() }
        let previous = Set(plugins.map(ObjectIdentifier.init))
        plugins = kept
        if let onChange {
            for plugin in plugins where !previous.contains(ObjectIdentifier(plugin)) && isEnabled(plugin.id) {
                plugin.start(onChange: onChange)
            }
        }
    }

    public func start(onChange: @escaping () -> Void) {
        self.onChange = onChange
        active.forEach { $0.start(onChange: onChange) }
    }

    public func stop() {
        all.forEach { $0.stop() }
        onChange = nil
    }

    public func refreshNow() {
        active.forEach { $0.refreshNow() }
    }

    public func pokeAll() {
        active.forEach { $0.poke() }
    }

    public func setEnabled(_ id: String, _ enabled: Bool) throws {
        if enabled { settings.disabled.remove(id) } else { settings.disabled.insert(id) }
        try settings.save(to: settingsFile)
        guard let module = all.first(where: { $0.id == id }) else { return }
        if enabled, let onChange {
            module.start(onChange: onChange)
        } else if !enabled {
            module.stop()
        }
        onChange?()
    }

    /// The "Plugins" submenu: every module with a tick to switch it, then what failed to load.
    public func pluginsMenu(toggle: @escaping (String, Bool) -> Void, openFolder: @escaping () -> Void,
                            reload: @escaping () -> Void) -> MenuNode {
        var children = all.map { module -> MenuNode in
            let enabled = isEnabled(module.id)
            var title = module.name
            if let plugin = module as? PluginModule {
                if !plugin.manifest.version.isEmpty { title += "  \(plugin.manifest.version)" }
            } else {
                title += "  (built in)"
            }
            let tip = (module as? PluginModule).map { $0.manifest.description.isEmpty ? $0.directory.path : $0.manifest.description }
            return MenuNode(title, action: .perform { toggle(module.id, !enabled) }, isChecked: enabled, toolTip: tip)
        }
        if !problems.isEmpty {
            children.append(.separator)
            children += problems.map { MenuNode.header("\($0.name)  ⚠︎  \($0.reason)".clipped(90)) }
        }
        children += [
            .separator,
            MenuNode("Open plugins folder…", action: .perform(openFolder)),
            MenuNode("Reload plugins", action: .perform(reload)),
        ]
        let count = plugins.count
        return MenuNode(count == 0 ? "Plugins" : "Plugins (\(count))", children: children)
    }
}
