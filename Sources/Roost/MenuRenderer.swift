import AppKit
import RoostCore
import SmartClipKit

/// Turns MenuNodes into NSMenuItems and performs their actions.
final class MenuRenderer: NSObject {
    /// Called after a command ran, so modules can refresh what it changed.
    var afterRun: (() -> Void)?

    private final class ActionBox {
        let action: MenuNode.Action
        let confirmation: String?
        init(_ action: MenuNode.Action, confirmation: String?) {
            self.action = action
            self.confirmation = confirmation
        }
    }

    func fill(_ menu: NSMenu, with nodes: [MenuNode]) {
        menu.removeAllItems()
        for node in nodes { menu.addItem(item(for: node)) }
    }

    private func item(for node: MenuNode) -> NSMenuItem {
        if node.isSeparator { return .separator() }
        let item = NSMenuItem(title: node.title, action: nil, keyEquivalent: "")
        item.toolTip = node.toolTip
        item.state = node.isChecked ? .on : .off
        if let action = node.action, node.isEnabled {
            item.target = self
            item.action = #selector(fire(_:))
            item.representedObject = ActionBox(action, confirmation: node.confirmation)
        }
        if !node.children.isEmpty {
            let submenu = NSMenu(title: node.title)
            submenu.autoenablesItems = false
            for child in node.children { submenu.addItem(self.item(for: child)) }
            item.submenu = submenu
        }
        item.isEnabled = node.isEnabled
        return item
    }

    @objc private func fire(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? ActionBox else { return }
        if let question = box.confirmation, !confirm(question, button: sender.title) { return }
        switch box.action {
        case .perform(let work):
            work()
        case .open(let target):
            let url = target.contains("://") ? URL(string: target) : URL(fileURLWithPath: (target as NSString).expandingTildeInPath)
            if let url { NSWorkspace.shared.open(url) }
        case .run(let argv):
            run(argv, toastOnSuccess: true)
        case .runQuietly(let argv):
            run(argv, toastOnSuccess: false)
        case .command(let command):
            run(command.argv, toastOnSuccess: true, environment: command.environment, directory: command.directory)
        }
    }

    /// A plain dialog in front of everything (Roost has no window of its own to put it on).
    private func confirm(_ question: String, button: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = question
        alert.addButton(withTitle: button.trimmingCharacters(in: CharacterSet(charactersIn: "…. ")))
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func run(_ argv: [String], toastOnSuccess: Bool,
                     environment: [String: String] = [:], directory: URL? = nil) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Shell.run(argv, timeout: 120, extraEnvironment: environment, directory: directory)
            DispatchQueue.main.async {
                let summary = result.summary
                if !summary.isEmpty && (toastOnSuccess || !result.ok) { Notifier.show(summary) }
                self?.afterRun?()
            }
        }
    }
}
