import AppKit
import RoostCore
import SmartClipKit

/// Turns MenuNodes into NSMenuItems and performs their actions.
final class MenuRenderer: NSObject {
    /// Called after a command ran, so modules can refresh what it changed.
    var afterRun: (() -> Void)?

    private final class ActionBox {
        let action: MenuNode.Action
        init(_ action: MenuNode.Action) { self.action = action }
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
            item.representedObject = ActionBox(action)
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
        }
    }

    private func run(_ argv: [String], toastOnSuccess: Bool) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Shell.run(argv, timeout: 120)
            DispatchQueue.main.async {
                let summary = result.summary
                if !summary.isEmpty && (toastOnSuccess || !result.ok) { Notifier.show(summary) }
                self?.afterRun?()
            }
        }
    }
}
