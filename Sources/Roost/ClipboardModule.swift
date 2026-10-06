import AppKit
import RoostCore
import SmartClipCore
import SmartClipKit

/// The Clipboard module: SmartClip's engine (capture, history, ⌥⌘V picker) hosted
/// in Roost. It shares SmartClip's store, so /cpy, /pst and /clh see the same history.
final class ClipboardModule: RoostModule {
    let id = "clipboard"
    let name = "Clipboard"
    let engine = SmartClipEngine()
    private var onChange: (() -> Void)?

    /// The stand-alone SmartClip.app, when it is also running: it would record every copy a second time.
    private var otherApp: NSRunningApplication? { SmartClipEngine.runningSmartClipApp() }

    var badge: Badge? {
        engine.isRunning && engine.isPaused ? Badge("paused", .info) : nil
    }

    func start(onChange: @escaping () -> Void) {
        self.onChange = onChange
        guard otherApp == nil else { return }  // let it keep recording until Jon chooses
        if !engine.start() {
            Notifier.show("⌥⌘V is taken by another app — use Roost's menu to search clips")
        }
    }

    func stop() {
        engine.stop()
    }

    func refreshNow() {}

    func menu() -> [MenuNode] {
        var nodes: [MenuNode] = [.header("Clipboard")]
        if let other = otherApp {
            nodes.append(.header("SmartClip.app is running and recording the clipboard itself"))
            nodes.append(MenuNode("Quit SmartClip.app and record here", action: .perform { [weak self] in
                self?.takeOver(from: other)
            }))
        }

        let clips = engine.recentClips(8)
        let recent = clips.isEmpty ? [MenuNode.header("Nothing copied yet")] : clips.map { record in
            MenuNode(String(record.displayText.prefix(60)), action: .perform { [weak self] in
                guard self?.engine.copy(record) == true else { return }
                Notifier.show("Copied — press ⌘V where you want it")
            }, toolTip: record.app.isEmpty ? record.type : "\(record.app) · \(record.type)")
        }
        nodes.append(MenuNode("Recent clips", children: recent))
        nodes.append(MenuNode("Search clips…  ⌥⌘V", action: .perform { [weak self] in self?.engine.showPicker() }))
        if engine.isRunning {
            nodes.append(MenuNode(engine.isPaused ? "Resume capture" : "Pause capture", action: .perform { [weak self] in
                guard let self else { return }
                self.engine.isPaused.toggle()
                Notifier.show(self.engine.isPaused ? "Clipboard capture paused" : "Clipboard capture on")
                self.onChange?()
            }))
            if !engine.hasAccessibility {
                nodes.append(MenuNode("Enable paste-back…", action: .perform { [weak self] in
                    self?.engine.requestAccessibility()
                }, toolTip: "Lets ⏎ in the picker press ⌘V for you"))
            }
        }
        let store = engine.store
        let used = ByteCountFormatter.string(fromByteCount: Int64(store.storedBytes()), countStyle: .file)
        let budget = ByteCountFormatter.string(fromByteCount: Int64(store.budgetBytes), countStyle: .file)
        nodes.append(.header("Archive: \(used) of \(budget)"))
        nodes.append(MenuNode("Open history folder", action: .open(store.dir.path)))
        return nodes
    }

    private func takeOver(from other: NSRunningApplication) {
        other.terminate()
        // Give it a moment to release ⌥⌘V before registering it here.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            let hotKey = self.engine.start()
            Notifier.show(hotKey ? "Roost is recording the clipboard now" : "Recording here; ⌥⌘V is still taken by another app")
            self.onChange?()
        }
    }
}
