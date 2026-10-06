import AppKit
import RoostCore
import SmartClipKit

let arguments = Array(CommandLine.arguments.dropFirst())

if arguments.contains("--version") {
    print("Roost 0.1.0")
    exit(0)
}

// `Roost --dump-menu` builds every module once and prints the menu as text, so the
// menu can be checked (and scripted against) without clicking the menu bar.
if arguments.contains("--dump-menu") {
    let registry = Modules.make()
    registry.refreshNow()
    let badge = Badge.mostUrgent(registry.active.map(\.badge))
    print("badge: \(badge.map { "\($0.text) (\($0.level))" } ?? "none")")
    let nodes = MenuComposer.compose(registry.active,
                                     appItems: AppItems.nodes(registry: registry, onToggleLogin: {}, onReload: {}))
    print(MenuDump.lines(nodes).joined(separator: "\n"))
    exit(0)
}

// Plugin commands: list, check, install and uninstall, without starting the app.
if let command = arguments.first, let code = PluginCommands.run(command, Array(arguments.dropFirst())) {
    exit(code)
}

// `Roost --show` opens the clipboard picker in the running app, like `SmartClip --show`.
if arguments.contains("--show") {
    DistributedNotificationCenter.default().postNotificationName(
        SmartClipEngine.showPickerNotification, object: nil, userInfo: nil, deliverImmediately: true)
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
app.run()
