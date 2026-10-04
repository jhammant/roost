import AppKit
import RoostCore
import ServiceManagement
import SmartClipKit

/// Builds Roost's modules. Shared by the app and `--dump-menu`.
enum Modules {
    static func make() -> (agents: AgentsModule, clipboard: ClipboardModule, scripts: ScriptsModule) {
        (AgentsModule(), ClipboardModule(), ScriptsModule())
    }
}

/// Roost's own items, below every module.
enum AppItems {
    static func nodes(onToggleLogin: @escaping () -> Void, onReload: @escaping () -> Void) -> [MenuNode] {
        let folder = ScriptsModule.defaultDirectory.path
        return [
            MenuNode("Open at login", action: .perform(onToggleLogin), isChecked: SMAppService.mainApp.status == .enabled),
            MenuNode("Script modules folder…", action: .perform {
                try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
                NSWorkspace.shared.open(URL(fileURLWithPath: folder))
            }, toolTip: "Executables here that print JSON become menus"),
            MenuNode("Refresh now", action: .perform(onReload)),
            .separator,
            MenuNode("Quit Roost", action: .perform { NSApp.terminate(nil) }),
        ]
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let agents: AgentsModule
    private let clipboard: ClipboardModule
    private let scripts: ScriptsModule
    private var modules: [RoostModule] { [agents, clipboard, scripts] }
    private let renderer = MenuRenderer()
    private var statusItem: NSStatusItem!

    override init() {
        (agents, clipboard, scripts) = Modules.make()
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "bird", accessibilityDescription: "Roost")
        statusItem.button?.imagePosition = .imageLeading
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu

        renderer.afterRun = { [weak self] in
            self?.agents.poke()
            self?.scripts.poke()
        }
        for module in modules {
            module.start { [weak self] in self?.updateBadge() }
        }
        registerAtLoginOnce()
        updateBadge()
    }

    func applicationWillTerminate(_ notification: Notification) {
        modules.forEach { $0.stop() }
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        let items = AppItems.nodes(onToggleLogin: { [weak self] in self?.toggleOpenAtLogin() },
                                   onReload: { [weak self] in self?.agents.poke(); self?.scripts.poke() })
        renderer.fill(menu, with: MenuComposer.compose(modules, appItems: items))
    }

    private func updateBadge() {
        guard let button = statusItem?.button else { return }
        guard let badge = Badge.mostUrgent(modules.map(\.badge)) else {
            button.attributedTitle = NSAttributedString(string: "")
            return
        }
        let colour: NSColor
        switch badge.level {
        case .alert: colour = .systemRed
        case .warn: colour = .systemOrange
        case .info: colour = .secondaryLabelColor
        }
        button.attributedTitle = NSAttributedString(string: " \(badge.text)", attributes: [
            .foregroundColor: colour,
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .semibold),
        ])
    }

    // MARK: - Login item

    /// Jon wants Roost always there, so it adds itself as a login item the first time
    /// it runs. After that the menu toggle is the only thing that changes it.
    private func registerAtLoginOnce() {
        let key = "registeredAtLoginOnce"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        if SMAppService.mainApp.status != .enabled {
            do {
                try SMAppService.mainApp.register()
                Notifier.show("Roost will open at login (turn it off in its menu)")
            } catch {
                Notifier.show("Couldn't add Roost to login items: \(error.localizedDescription)")
            }
        }
    }

    private func toggleOpenAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
                Notifier.show("Roost will not open at login")
            } else {
                try SMAppService.mainApp.register()
                Notifier.show("Roost will open at login")
            }
        } catch {
            Notifier.show("Couldn't change the login item: \(error.localizedDescription)")
        }
    }
}
