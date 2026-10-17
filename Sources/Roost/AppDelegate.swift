import AppKit
import RoostCore
import ServiceManagement
import SmartClipKit

/// Builds Roost's modules: Agents and Clipboard, then the installed plugins, then
/// script modules. Shared by the app and the command line.
enum Modules {
    static func make() -> ModuleRegistry {
        ModuleRegistry(leading: [AgentsModule(), ClipboardModule()], trailing: [ScriptsModule()])
    }
}

/// Roost's own items, below every module.
enum AppItems {
    static func nodes(registry: ModuleRegistry, onToggleLogin: @escaping () -> Void, onReload: @escaping () -> Void) -> [MenuNode] {
        let folder = ScriptsModule.defaultDirectory.path
        let plugins = registry.pluginsDirectory
        return [
            registry.pluginsMenu(toggle: { id, enabled in
                do {
                    try registry.setEnabled(id, enabled)
                } catch {
                    Notifier.show("Couldn't save Roost's settings: \(error.localizedDescription)")
                }
            }, openFolder: {
                try? FileManager.default.createDirectory(at: plugins, withIntermediateDirectories: true)
                NSWorkspace.shared.open(plugins)
            }, reload: onReload),
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
    private let registry = Modules.make()
    private let renderer = MenuRenderer()
    private var statusItem: NSStatusItem!
    private var pluginWatch: Timer?
    private var hotKeys: HotKeyCenter?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "bird", accessibilityDescription: "Roost")
        statusItem.button?.imagePosition = .imageLeading
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu

        renderer.afterRun = { [weak self] in self?.registry.pokeAll() }
        registry.start { [weak self] in self?.refreshed() }
        hotKeys = HotKeyCenter(fire: { [weak self] node in self?.renderer.perform(node) })
        // Pick up plugins installed or removed while Roost runs, so their badges show
        // without opening the menu first. Unchanged plugins are left running.
        pluginWatch = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.registry.reload()
            self?.refreshed()
        }
        registerAtLoginOnce()
        refreshed()
    }

    /// A module changed: redraw the badge and pick up shortcuts that were added, moved or dropped.
    private func refreshed() {
        updateBadge()
        // Only plugins and script modules declare shortcuts; the built-in menus are not rebuilt for this.
        let declaring = registry.active.filter { $0 is PluginModule || $0 is ScriptsModule }
        hotKeys?.update(HotKeys.collect(declaring.flatMap { $0.menu() }))
    }

    func applicationWillTerminate(_ notification: Notification) {
        registry.stop()
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        registry.reload()
        let items = AppItems.nodes(registry: registry,
                                   onToggleLogin: { [weak self] in self?.toggleOpenAtLogin() },
                                   onReload: { [weak self] in
                                       self?.registry.reload()
                                       self?.registry.pokeAll()
                                   })
        renderer.fill(menu, with: MenuComposer.compose(registry.active, appItems: items))
    }

    private func updateBadge() {
        guard let button = statusItem?.button else { return }
        guard let badge = Badge.mostUrgent(registry.active.map(\.badge)) else {
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
