import Foundation

/// The Agents module: atc (air traffic control for coding agents) in the menu bar.
/// It polls `atc --json`, badges the icon with who is blocked on you (red) or
/// waiting for you, and every click hands back to atc (`--jump`, `--cap`, `--open`).
public final class AgentsModule: RoostModule {
    public let id = "agents"
    public let atc: String
    public var interval: TimeInterval = 5
    public var providersInterval: TimeInterval = 60
    public var hostsInterval: TimeInterval = 60   // servers are read over ssh: slower, and they change slowly
    private var hosts: Any?
    private var hostsAt = Date.distantPast

    private let queue = DispatchQueue(label: "io.hammant.roost.agents", qos: .utility)
    private let lock = NSLock()
    private var model: [String: Any]?
    private var error: String?
    private var providers: [[String: Any]] = []
    private var providersAt = Date.distantPast
    private var running = false
    private let wake = DispatchSemaphore(value: 0)

    public init(atc: String = NSHomeDirectory() + "/.local/bin/atc") {
        self.atc = atc
    }

    public var badge: Badge? { snapshot().badge }

    public func menu() -> [MenuNode] { snapshot().nodes }

    private func snapshot() -> (nodes: [MenuNode], badge: Badge?) {
        lock.lock()
        let model = self.model, error = self.error, providers = self.providers
        lock.unlock()
        return AgentsMenu.build(model: model, error: error, providers: providers, atc: atc)
    }

    public func refreshNow() {
        let withHosts = Date().timeIntervalSince(hostsAt) > hostsInterval
        let result = Shell.run(withHosts ? [atc, "--json"] : [atc, "--json", "--no-hosts"], timeout: 90)
        var parsed = result.ok ? (try? JSONSerialization.jsonObject(with: result.stdout)) as? [String: Any] : nil
        if withHosts, let fresh = parsed?["hosts"] {
            hosts = fresh
            hostsAt = Date()
        } else if parsed != nil, let hosts {
            parsed?["hosts"] = hosts  // keep the last reading of the servers between their slower polls
        }
        var fresh: [[String: Any]]?
        if Date().timeIntervalSince(providersAt) > providersInterval, let quotamax = Shell.which("quotamax") {
            let answer = Shell.run([quotamax, "providers", "--json"], timeout: 30)
            fresh = answer.ok ? (try? JSONSerialization.jsonObject(with: answer.stdout)) as? [[String: Any]] : nil
            providersAt = Date()
        }
        lock.lock()
        if let parsed {
            model = parsed
            error = nil
        } else {
            error = result.ok ? "atc printed something that isn't JSON" : result.summary
        }
        if let fresh { providers = fresh }
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

    /// Refresh soon, e.g. right after a click changed something.
    public func poke() {
        wake.signal()
    }
}

/// Turns atc's `--json` model into menu lines. Pure, so it is tested with fixtures.
public enum AgentsMenu {
    static let capSize = ["critical": 1, "constrained": 2, "comfortable": 4, "abundant": 8]

    public static func build(model: [String: Any]?, error: String?, providers: [[String: Any]],
                             atc: String) -> (nodes: [MenuNode], badge: Badge?) {
        guard let model else {
            let status = error.map { "atc: \($0)" } ?? "Reading your agents…"
            return ([.header("Agents"), .header(status.clipped(90)),
                     MenuNode("Open atc…", action: .run([atc, "--open"]))], nil)
        }
        let groups = model["groups"] as? [String: Any] ?? [:]
        func group(_ key: String) -> [[String: Any]] { groups[key] as? [[String: Any]] ?? [] }
        let blocked = group("blocked"), waiting = group("waiting"), working = group("working")

        var summary: [String] = []
        if !blocked.isEmpty { summary.append("\(blocked.count) blocked") }
        summary.append("\(waiting.count) waiting")
        summary.append("\(working.count) working")
        var nodes: [MenuNode] = [.header("Agents — " + summary.joined(separator: " · "))]
        if let error { nodes.append(.header("⚠︎ last refresh failed: \(error)".clipped(90))) }

        func sessions(_ items: [[String: Any]], mark: String, limit: Int) -> [MenuNode] {
            var out = items.prefix(limit).map { session -> MenuNode in
                let name = session["name"] as? String ?? "?"
                let doing = (session["doing"] as? String ?? "").firstLine
                let sid = session["sid"] as? String ?? ""
                let state = (session["state"] as? String).map { " · \($0)" } ?? ""
                let tip = [session["title"] as? String, session["cwd"] as? String].compactMap { $0 }
                    .filter { !$0.isEmpty }.joined(separator: " — ")
                return MenuNode("\(mark)  \(name)\(state) — \(doing)".clipped(100),
                                action: sid.isEmpty ? nil : .runQuietly([atc, "--jump", sid]),
                                toolTip: tip.isEmpty ? nil : tip)
            }
            if items.count > limit {
                out.append(MenuNode("     … \(items.count - limit) more in atc", action: .run([atc, "--open"])))
            }
            return out
        }
        if !blocked.isEmpty { nodes += [.header("Blocked on you")] + sessions(blocked, mark: "!", limit: 20) }
        if !waiting.isEmpty { nodes += [.header("Waiting on you")] + sessions(waiting, mark: "◆", limit: 8) }
        if !working.isEmpty { nodes += [.header("Working")] + sessions(working, mark: "●", limit: 8) }
        let quiet = ["parked", "background", "other"].map { (key: $0, count: group($0).count) }.filter { $0.count > 0 }
        if !quiet.isEmpty {
            nodes.append(.header("     " + quiet.map { "\($0.count) \($0.key)" }.joined(separator: " · ")))
        }

        let agents = model["agents"] as? [[String: Any]] ?? []
        if !agents.isEmpty {
            nodes.append(MenuNode("Other agents (\(agents.count))", children: agents.map(agentLine)))
        }
        if let hosts = model["hosts"] as? [[String: Any]], !hosts.isEmpty {
            nodes.append(.header("Servers"))
            nodes += hosts.map(hostNode)
        }

        let quota = model["quota"] as? [String: Any]
        if let line = quotaLine(quota, providers: providers) { nodes.append(.header(line)) }
        if let cap = capTitle(quota) {
            nodes.append(MenuNode(cap, children: [
                MenuNode("Raise", action: .run([atc, "--cap", "up"])),
                MenuNode("Lower", action: .run([atc, "--cap", "down"])),
                MenuNode("Back to auto (follow measured quota)", action: .run([atc, "--cap", "auto"])),
            ]))
        }
        nodes.append(MenuNode("Open atc…", action: .run([atc, "--open"])))

        let badge = !blocked.isEmpty ? Badge("\(blocked.count)", .alert)
            : (!waiting.isEmpty ? Badge("\(waiting.count)", .warn) : nil)
        return (nodes, badge)
    }

    static func agentLine(_ agent: [String: Any]) -> MenuNode {
        let tool = agent["tool"] as? String ?? "agent"
        let up = (agent["etime"] as? String).map { "up \(humanAge(etimeSeconds($0)))" } ?? ""
        let stale = isStale(agent) ? "  stale?" : ""
        let command = (agent["command"] as? String ?? "").clipped(70)
        return .header("\(tool)  \(up)\(stale)  \(command)")
    }

    static func hostNode(_ host: [String: Any]) -> MenuNode {
        let name = host["host"] as? String ?? "?"
        if let ok = host["ok"] as? Bool, !ok {
            let why = (host["error"] as? String ?? "unreachable").firstLine
            return .header("\(name): \(why)".clipped(90))
        }
        let counts = host["counts"] as? [String: Any] ?? [:]
        let agents = host["agents"] as? [[String: Any]] ?? []
        var parts: [String] = []
        if let live = counts["live"] as? Int, live > 0 { parts.append("\(live) session\(live == 1 ? "" : "s")") }
        parts.append("\(agents.count) agent\(agents.count == 1 ? "" : "s")")
        let stale = agents.filter(isStale).count
        if stale > 0 { parts.append("\(stale) stale") }
        if let blocked = counts["blocked"] as? Int, blocked > 0 { parts.append("\(blocked) blocked") }
        let title = "\(name): " + parts.joined(separator: ", ")
        return agents.isEmpty ? .header(title) : MenuNode(title, children: agents.map(agentLine))
    }

    /// Running for over a day: an agent process that never finished is usually stuck or leaked.
    static func isStale(_ agent: [String: Any]) -> Bool {
        if let stale = agent["stale"] as? Bool { return stale }
        return (agent["etime"] as? String).map { etimeSeconds($0) > 86_400 } ?? false
    }

    static func quotaLine(_ quota: [String: Any]?, providers: [[String: Any]]) -> String? {
        var parts: [String] = []
        if let quota {
            let session = (quota["session"] as? [String: Any])?["percentUsed"]
            let weekly = quota["weekly"] as? [String: Any]
            let week = weekly?["effectivePercent"] ?? weekly?["percentUsed"]
            if let session, let week { parts.append("Claude 5h \(session)% · week \(week)%") }
        }
        for provider in providers where (provider["ok"] as? Bool ?? true) && (provider["id"] as? String) != "claude" {
            let label = (provider["label"] as? String ?? provider["id"] as? String ?? "?")
                .split(separator: " ").first.map(String.init) ?? "?"
            var bits = (provider["limits"] as? [[String: Any]] ?? []).compactMap { limit -> String? in
                guard let percent = limit["percent"] else { return nil }
                let name = (limit["label"] as? String ?? "").replacingOccurrences(of: " window", with: "")
                return "\(name) \(percent)%"
            }
            if let balance = provider["balanceUsd"] as? Double { bits.append(String(format: "$%.2f", balance)) }
            if !bits.isEmpty { parts.append("\(label) " + bits.joined(separator: " · ")) }
        }
        return parts.isEmpty ? nil : "Quota: " + parts.joined(separator: "   ")
    }

    static func capTitle(_ quota: [String: Any]?) -> String? {
        guard let quota else { return nil }
        let override = quota["override"] as? [String: Any]
        guard let level = override?["level"] as? String ?? quota["headroom"] as? String else { return nil }
        let size = capSize[level] ?? (quota["advice"] as? [String: Any])?["parallelism"] as? Int ?? 0
        return "Swarm cap: ≤\(size) \(level) (\(override?["level"] == nil ? "auto" : "pinned"))"
    }

    /// ps's elapsed time, [[dd-]hh:]mm:ss, in seconds.
    static func etimeSeconds(_ etime: String) -> Int {
        let pieces = etime.split(separator: "-", maxSplits: 1)
        let days = pieces.count == 2 ? Int(pieces[0]) ?? 0 : 0
        let clock = pieces.last.map(String.init) ?? ""
        let seconds = clock.split(separator: ":").reduce(0) { $0 * 60 + (Int($1) ?? 0) }
        return days * 86_400 + seconds
    }

    static func humanAge(_ seconds: Int) -> String {
        switch seconds {
        case ..<60: return "\(seconds)s"
        case ..<3600: return "\(seconds / 60)m"
        case ..<86_400: return "\(seconds / 3600)h"
        default: return "\(seconds / 86_400)d"
        }
    }
}
