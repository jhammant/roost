import Foundation
import RoostCore

/// `Roost --plugins`, `--check-plugin DIR`, `--install-plugin DIR` and `--uninstall-plugin ID`.
/// They work on the plugins folder directly, so they need no running app and no menu bar.
enum PluginCommands {
    /// The exit status, or nil when `command` isn't a plugin command.
    static func run(_ command: String, _ arguments: [String]) -> Int32? {
        let folder = PluginDiscovery.defaultDirectory
        switch command {
        case "--plugins":
            return list(folder)
        case "--check-plugin":
            guard let path = arguments.first else { return usage("--check-plugin <plugin folder>") }
            return check(URL(fileURLWithPath: path))
        case "--install-plugin":
            guard let path = arguments.first else { return usage("--install-plugin <plugin folder>") }
            return install(URL(fileURLWithPath: path), into: folder)
        case "--uninstall-plugin":
            guard let id = arguments.first else { return usage("--uninstall-plugin <plugin id>") }
            return uninstall(id, from: folder)
        default:
            return nil
        }
    }

    private static func usage(_ text: String) -> Int32 {
        printError("usage: Roost \(text)")
        return 2
    }

    private static func printError(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }

    static func list(_ folder: URL) -> Int32 {
        let settings = RoostSettings.load(from: RoostSettings.defaultFile)
        let found = PluginDiscovery.scan(folder)
        print("Plugins in \(folder.path)")
        if found.isEmpty { print("  (none)") }
        for plugin in found {
            switch plugin.manifest {
            case .success(let manifest):
                let state = settings.disabled.contains(manifest.id) ? "off" : "on "
                let version = manifest.version.isEmpty ? "" : " \(manifest.version)"
                print("  \(state)  \(manifest.id)\(version)  every \(Int(manifest.interval))s  \(plugin.directory.path)")
            case .failure(let error):
                print("  ⚠︎   \(plugin.directory.lastPathComponent): \(error)")
            }
        }
        if !settings.disabled.isEmpty {
            print("Switched off: \(settings.disabled.sorted().joined(separator: ", "))")
        }
        return 0
    }

    /// Runs the plugin once and prints its menu, exactly as Roost would show it.
    static func check(_ directory: URL) -> Int32 {
        let directory = directory.standardizedFileURL.resolvingSymlinksInPath()
        let manifest: PluginManifest
        do {
            manifest = try PluginManifest.load(from: directory)
        } catch {
            printError("\(directory.path): \(error)")
            return 1
        }
        let plugin = PluginModule(manifest: manifest, directory: directory)
        let started = Date()
        plugin.refreshNow()
        let took = Date().timeIntervalSince(started)
        print("\(manifest.id): \(manifest.name), every \(Int(manifest.interval))s, timeout \(Int(manifest.timeout))s, ran in \(String(format: "%.1f", took))s")
        print("badge: \(plugin.badge.map { "\($0.text) (\($0.level))" } ?? "none")")
        let menu = plugin.menu()
        print(MenuDump.lines(menu).joined(separator: "\n"))
        return menu.first?.title.hasSuffix("⚠︎") == true ? 1 : 0
    }

    static func install(_ directory: URL, into folder: URL) -> Int32 {
        let source = directory.standardizedFileURL.resolvingSymlinksInPath()
        let manifest: PluginManifest
        do {
            manifest = try PluginManifest.load(from: source)
        } catch {
            printError("\(source.path): \(error)")
            return 1
        }
        let link = folder.appendingPathComponent(manifest.id)
        let manager = FileManager.default
        if let existing = try? manager.destinationOfSymbolicLink(atPath: link.path) {
            if URL(fileURLWithPath: existing).standardizedFileURL.resolvingSymlinksInPath() == source {
                print("\(manifest.id) is already installed from \(source.path)")
                return check(source)
            }
            printError("\(link.path) already points at \(existing); run --uninstall-plugin \(manifest.id) first")
            return 1
        }
        if manager.fileExists(atPath: link.path) {
            printError("\(link.path) already exists")
            return 1
        }
        do {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            try manager.createSymbolicLink(atPath: link.path, withDestinationPath: source.path)
        } catch {
            printError("Couldn't link the plugin: \(error.localizedDescription)")
            return 1
        }
        print("Installed \(manifest.id): \(link.path) → \(source.path)")
        print("A running Roost picks it up within 30 seconds, or at once from Plugins ▸ Reload plugins.")
        _ = check(source)
        return 0
    }

    static func uninstall(_ id: String, from folder: URL) -> Int32 {
        let link = folder.appendingPathComponent(id)
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil else {
            printError(FileManager.default.fileExists(atPath: link.path)
                       ? "\(link.path) is a real folder, not a link Roost made; remove it yourself if you mean to"
                       : "No plugin installed as \(id)")
            return 1
        }
        do {
            try FileManager.default.removeItem(at: link)
        } catch {
            printError("Couldn't remove \(link.path): \(error.localizedDescription)")
            return 1
        }
        print("Uninstalled \(id) (its folder is untouched)")
        return 0
    }
}
