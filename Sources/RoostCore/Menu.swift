import Foundation

/// One line of the Roost menu, described as data. Modules build these instead of
/// NSMenuItems, so they need no AppKit and the whole menu can be printed with
/// `Roost --dump-menu`.
public struct MenuNode {
    public enum Action {
        case run([String])          // a command, as argv; its first line of output is shown as a toast
        case runQuietly([String])   // a command whose success you can see (a tab comes forward): toast only on failure
        case command(Command)       // a plugin's command: run in its folder with its environment, toast like `run`
        case open(String)           // a URL or a file path
        case perform(() -> Void)    // in-process work (the Clipboard module)
    }

    /// A command that belongs to a plugin, so it runs where the plugin's own refresh runs.
    public struct Command {
        public var argv: [String]
        public var directory: URL?
        public var environment: [String: String]

        public init(_ argv: [String], directory: URL? = nil, environment: [String: String] = [:]) {
            self.argv = argv
            self.directory = directory
            self.environment = environment
        }
    }

    public var title: String
    public var action: Action?
    public var children: [MenuNode]
    public var isEnabled: Bool
    public var isChecked: Bool
    public var isSeparator = false
    public var toolTip: String?
    /// When set, Roost asks this question and only acts on "OK". For anything with side effects.
    public var confirmation: String?

    public init(_ title: String, action: Action? = nil, children: [MenuNode] = [],
                isEnabled: Bool = true, isChecked: Bool = false, toolTip: String? = nil,
                confirmation: String? = nil) {
        self.title = title
        self.action = action
        self.children = children
        self.isEnabled = isEnabled
        self.isChecked = isChecked
        self.toolTip = toolTip
        self.confirmation = confirmation
    }

    /// A greyed-out line that names a section or just reports something.
    public static func header(_ title: String) -> MenuNode {
        MenuNode(title, isEnabled: false)
    }

    public static var separator: MenuNode {
        var node = MenuNode("")
        node.isSeparator = true
        return node
    }
}

/// The text next to Roost's icon. The most urgent badge across all modules wins.
public struct Badge: Equatable {
    public enum Level: Int, Comparable {
        case info, warn, alert
        public static func < (lhs: Level, rhs: Level) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public var text: String
    public var level: Level

    public init(_ text: String, _ level: Level) {
        self.text = text
        self.level = level
    }

    public static func mostUrgent(_ badges: [Badge?]) -> Badge? {
        badges.compactMap { $0 }.reduce(nil) { best, badge in
            guard let best else { return badge }
            return badge.level > best.level ? badge : best
        }
    }
}

/// Something that lives in Roost's menu. Modules refresh on their own schedule and
/// call `onChange` (on the main queue) when their menu or badge may have changed.
public protocol RoostModule: AnyObject {
    var id: String { get }
    /// What the Plugins menu calls it.
    var name: String { get }
    var badge: Badge? { get }
    func start(onChange: @escaping () -> Void)
    func stop()
    /// Refresh synchronously, for `--dump-menu` and tests.
    func refreshNow()
    /// Refresh soon, e.g. right after a click changed something.
    func poke()
    func menu() -> [MenuNode]
}

public extension RoostModule {
    var name: String { id.capitalized }
    func poke() {}
}

public enum MenuComposer {
    /// Each module's section, separated, then the app's own items.
    public static func compose(_ modules: [RoostModule], appItems: [MenuNode]) -> [MenuNode] {
        var out: [MenuNode] = []
        for module in modules {
            let section = module.menu()
            guard !section.isEmpty else { continue }
            if !out.isEmpty { out.append(.separator) }
            out += section
        }
        if !out.isEmpty { out.append(.separator) }
        return out + appItems
    }
}

public enum MenuDump {
    /// The menu as indented text: `▸` marks a submenu, `[…]` what a click does, `·` a greyed line.
    public static func lines(_ nodes: [MenuNode], depth: Int = 0) -> [String] {
        var out: [String] = []
        let pad = String(repeating: "    ", count: depth)
        for node in nodes {
            if node.isSeparator {
                out.append(pad + "────────")
                continue
            }
            var line = pad + (node.isChecked ? "✓ " : "") + (node.isEnabled ? "" : "· ") + node.title
            switch node.action {
            case .run(let argv)?: line += "    [run: \(argv.joined(separator: " "))]"
            case .runQuietly(let argv)?: line += "    [run quietly: \(argv.joined(separator: " "))]"
            case .command(let command)?: line += "    [run: \(command.argv.joined(separator: " "))]"
            case .open(let target)?: line += "    [open: \(target)]"
            case .perform?: line += "    [action]"
            case nil: break
            }
            if let question = node.confirmation { line += "  [confirm: \(question)]" }
            if !node.children.isEmpty { line += "  ▸" }
            out.append(line)
            out += lines(node.children, depth: depth + 1)
        }
        return out
    }
}

extension String {
    var firstLine: String {
        split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    }

    func clipped(_ limit: Int) -> String {
        count <= limit ? self : String(prefix(max(0, limit - 1))) + "…"
    }
}
