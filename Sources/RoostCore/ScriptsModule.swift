import Foundation

/// Script modules: any executable in ~/.config/roost/modules becomes a submenu.
/// It is run every 30 seconds and prints JSON:
///
///     {"title": "Servers", "badge": "2",
///      "items": [{"title": "buildbox: ok", "open": "https://buildbox.local"},
///                {"title": "Restart", "run": "ssh buildbox sudo systemctl restart x"},
///                {"title": "More", "items": [ … ]}]}
///
/// So a new tool can join the menu bar without any Swift.
public final class ScriptsModule: RoostModule {
    public let id = "scripts"
    public let directory: URL
    public var interval: TimeInterval = 30
    public var timeout: TimeInterval = 10

    private let queue = DispatchQueue(label: "io.hammant.roost.scripts", qos: .utility)
    private let lock = NSLock()
    private var results: [(name: String, result: ScriptResult)] = []
    private var running = false
    private let wake = DispatchSemaphore(value: 0)

    /// ~/.config/roost/modules, or ROOST_MODULES_DIR.
    public static var defaultDirectory: URL {
        if let custom = ProcessInfo.processInfo.environment["ROOST_MODULES_DIR"], !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config/roost/modules", isDirectory: true)
    }

    public init(directory: URL = ScriptsModule.defaultDirectory) {
        self.directory = directory
    }

    public var badge: Badge? {
        lock.lock()
        defer { lock.unlock() }
        return Badge.mostUrgent(results.map(\.result.badge))
    }

    public func menu() -> [MenuNode] {
        lock.lock()
        defer { lock.unlock() }
        return results.map(\.result.node)
    }

    public func scripts() -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.sorted()
            .filter { !$0.hasPrefix(".") }
            .map { directory.appendingPathComponent($0) }
            .filter { FileManager.default.isExecutableFile(atPath: $0.path) && !$0.hasDirectoryPath }
    }

    public func refreshNow() {
        let fresh = scripts().map { url -> (name: String, result: ScriptResult) in
            let name = url.deletingPathExtension().lastPathComponent
            let output = Shell.run([url.path], timeout: timeout)
            guard output.ok else {
                return (name, ScriptMenu.failure(title: name, reason: output.summary))
            }
            return (name, ScriptMenu.parse(output.stdout, fallbackTitle: name))
        }
        lock.lock()
        results = fresh
        lock.unlock()
    }

    public func start(onChange: @escaping () -> Void) {
        guard !running else { return }
        running = true
        queue.async { [weak self] in
            while let self = self, self.running {
                self.refreshNow()
                DispatchQueue.main.async(execute: onChange)
                _ = self.wake.wait(timeout: .now() + self.interval)
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

public struct ScriptResult {
    public var node: MenuNode
    public var badge: Badge?
}

public enum ScriptMenu {
    public static func parse(_ data: Data, fallbackTitle: String) -> ScriptResult {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return failure(title: fallbackTitle, reason: "didn't print a JSON object")
        }
        let title = (object["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? fallbackTitle
        let items = (object["items"] as? [[String: Any]] ?? []).map(node)
        let badge = parseBadge(object["badge"])
        let shown = badge.map { "\(title)  (\($0.text))" } ?? title
        return ScriptResult(node: MenuNode(shown, children: items.isEmpty ? [.header("(nothing to show)")] : items),
                            badge: badge)
    }

    public static func failure(title: String, reason: String) -> ScriptResult {
        ScriptResult(node: MenuNode("\(title)  ⚠︎", children: [.header("error: \(reason)".clipped(90))]), badge: nil)
    }

    static func node(_ item: [String: Any]) -> MenuNode {
        let title = item["title"] as? String ?? "?"
        let children = (item["items"] as? [[String: Any]] ?? []).map(node)
        var action: MenuNode.Action?
        if let command = item["run"] as? String {
            action = .run(["/bin/sh", "-c", command])
        } else if let argv = item["run"] as? [String], !argv.isEmpty {
            action = .run(argv)
        } else if let target = item["open"] as? String {
            action = .open(target)
        }
        let enabled = (item["disabled"] as? Bool).map { !$0 } ?? (action != nil || !children.isEmpty)
        return MenuNode(title, action: action, children: children, isEnabled: enabled,
                        isChecked: item["checked"] as? Bool ?? false, toolTip: item["tooltip"] as? String)
    }

    static func parseBadge(_ value: Any?) -> Badge? {
        if let text = value as? String, !text.isEmpty { return Badge(text, .info) }
        if let number = value as? Int, number != 0 { return Badge("\(number)", .info) }
        guard let badge = value as? [String: Any], let text = badge["text"] as? String ?? (badge["text"] as? Int).map(String.init),
              !text.isEmpty else { return nil }
        let level: Badge.Level = ["alert": .alert, "error": .alert, "warn": .warn, "warning": .warn][badge["level"] as? String ?? ""] ?? .info
        return Badge(text, level)
    }
}
