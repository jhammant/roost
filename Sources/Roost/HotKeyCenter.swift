import AppKit
import Carbon.HIToolbox
import RoostCore
import SmartClipKit

/// System-wide shortcuts for menu items that ask for one (`"hotkey"` in a plugin's JSON).
///
/// Carbon's `RegisterEventHotKey`, like SmartClip's ⌥⌘V, because it needs no Accessibility
/// grant. Every hotkey in the app arrives at the same handler chain, so each handler (this one
/// and SmartClip's) acts only on its own signature and passes everything else on.
final class HotKeyCenter {
    private static let signature = OSType(0x524F5354) // 'ROST'

    private var handler: EventHandlerRef?
    private var registered: [HotKeySpec: (ref: EventHotKeyRef, id: UInt32)] = [:]
    private var actions: [UInt32: MenuNode] = [:]
    private var nextID: UInt32 = 1
    /// Combinations another app already owns: reported once, not retried on every refresh.
    private(set) var taken: Set<HotKeySpec> = []
    private let fire: (MenuNode) -> Void

    init(fire: @escaping (MenuNode) -> Void) {
        self.fire = fire
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData -> OSStatus in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr, id.signature == HotKeyCenter.signature else { return OSStatus(eventNotHandledErr) }
            let center = Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
            guard let node = center.actions[id.id] else { return OSStatus(eventNotHandledErr) }
            center.fire(node)
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    deinit {
        registered.values.forEach { UnregisterEventHotKey($0.ref) }
        if let handler { RemoveEventHandler(handler) }
    }

    /// Registers what the menus ask for now and drops what they no longer ask for. Cheap when nothing changed,
    /// so it runs on every refresh; the item a shortcut fires is always the latest one with that combination.
    func update(_ wanted: [(spec: HotKeySpec, node: MenuNode)]) {
        let specs = Set(wanted.map(\.spec))
        for (spec, entry) in registered where !specs.contains(spec) {
            UnregisterEventHotKey(entry.ref)
            actions[entry.id] = nil
            registered[spec] = nil
        }
        taken = taken.intersection(specs)
        for (spec, node) in wanted {
            if let entry = registered[spec] {
                actions[entry.id] = node
                continue
            }
            guard !taken.contains(spec) else { continue }
            var ref: EventHotKeyRef?
            let id = nextID
            nextID += 1
            let status = RegisterEventHotKey(spec.keyCode, spec.modifiers, EventHotKeyID(signature: Self.signature, id: id),
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                registered[spec] = (ref, id)
                actions[id] = node
            } else {
                taken.insert(spec)
                Notifier.show("\(spec.display) is already used by another app, so “\(node.title)” has no shortcut")
            }
        }
    }
}
