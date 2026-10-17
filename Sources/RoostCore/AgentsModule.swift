import Foundation

/// The Agents module: atc (air traffic control for coding agents) in the menu bar.
/// It polls `atc --json`, badges urgent needs, failing jobs or waiting sessions,
/// and hands approvals back to the atc web UI.
public final class AgentsModule: RoostModule {
    public let id = "agents"
    public let name = "Agents"
    public let atc: String
    public let webURL: String?
    public var interval: TimeInterval = 5
    public var providersInterval: TimeInterval = 60
    public var hostsInterval: TimeInterval = 60   // servers are read over ssh: slower, and they change slowly
    private var hostModel: [String: Any]?
    private var hostsAt = Date.distantPast

    private let queue = DispatchQueue(label: "io.hammant.roost.agents", qos: .utility)
    private let lock = NSLock()
    private var model: [String: Any]?
    private var error: String?
    private var providers: [[String: Any]] = []
    private var providersAt = Date.distantPast
    private var running = false
    private let wake = DispatchSemaphore(value: 0)

    public init(atc: String = NSHomeDirectory() + "/.local/bin/atc",
                webURL: String? = AgentsModule.configuredWebURL()) {
        self.atc = atc
        self.webURL = webURL
    }

    /// `ATC_WEB_URL`, else the first line of `~/.config/atc/web-url`: an app started at login has no shell
    /// environment, so the file is how most people set it.
    public static func configuredWebURL(environment: [String: String] = ProcessInfo.processInfo.environment,
                                        file: String = NSHomeDirectory() + "/.config/atc/web-url") -> String? {
        if let url = environment["ATC_WEB_URL"]?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty {
            return url
        }
        guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { return nil }
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        return line.hasPrefix("https://") || line.hasPrefix("http://") ? line : nil
    }

    public var badge: Badge? { snapshot().badge }

    public func menu() -> [MenuNode] { snapshot().nodes }

    private func snapshot() -> (nodes: [MenuNode], badge: Badge?) {
        lock.lock()
        let model = self.model, error = self.error, providers = self.providers
        lock.unlock()
        return AgentsMenu.build(model: model, error: error, providers: providers, atc: atc, webURL: webURL)
    }

    public func refreshNow() {
        let withHosts = Date().timeIntervalSince(hostsAt) > hostsInterval
        let result = Shell.run(withHosts ? [atc, "--json"] : [atc, "--json", "--no-hosts"], timeout: 90)
        var parsed = result.ok ? (try? JSONSerialization.jsonObject(with: result.stdout)) as? [String: Any] : nil
        if withHosts, let fresh = parsed {
            hostModel = fresh
            hostsAt = Date()
        } else if let fresh = parsed, let hostModel {
            parsed = Self.preservingRemoteData(in: fresh, from: hostModel)
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
                // This block never returns, so GCD never drains its autorelease pool: without
                // our own, every poll's output and parsed JSON stay alive (37 GB in six days).
                autoreleasepool { self.refreshNow() }
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

    /// Fast polls omit atc peers. Keep their needs along with their session snapshot;
    /// loom's own hosts are still refreshed on every poll and must not be overwritten.
    static func preservingRemoteData(in fresh: [String: Any], from previous: [String: Any]) -> [String: Any] {
        var model = fresh
        model["hosts"] = previous["hosts"]
        let peers = Set((previous["hosts"] as? [[String: Any]] ?? []).compactMap { $0["host"] as? String })
        let freshJobs = fresh["jobs"] as? [String: [String: Any]] ?? [:]
        var counts = fresh["counts"] as? [String: Any] ?? [:]
        if var needs = fresh["needs"] as? [[String: Any]] {
            let remote = (previous["needs"] as? [[String: Any]] ?? []).filter {
                let host = $0["host"] as? String ?? ""
                if $0["kind"] as? String == "job" {
                    return $0["via"] as? String != nil && freshJobs[host] == nil
                }
                return peers.contains(host)
            }
            needs += remote
            model["needs"] = needs
            counts["needs"] = needs.count
            counts["needs_urgent"] = (counts["needs_urgent"] as? Int
                ?? (fresh["needs"] as? [[String: Any]] ?? []).filter(AgentsMenu.isUrgent).count)
                + remote.filter(AgentsMenu.isUrgent).count
        }
        if var jobs = fresh["jobs"] as? [String: [String: Any]] {
            let remote = (previous["jobs"] as? [String: [String: Any]] ?? [:]).filter {
                $0.value["via"] as? String != nil && jobs[$0.key] == nil
            }
            let remoteFailures = remote.values.flatMap { $0["jobs"] as? [[String: Any]] ?? [] }
                .filter { $0["failing"] as? Bool == true }.count
            let localFailures = jobs.values.flatMap { $0["jobs"] as? [[String: Any]] ?? [] }
                .filter { $0["failing"] as? Bool == true }.count
            jobs.merge(remote) { current, _ in current }
            model["jobs"] = jobs
            counts["jobs_failing"] = (counts["jobs_failing"] as? Int ?? localFailures) + remoteFailures
        }
        if let later = fresh["later"] as? [[String: Any]] {
            model["later"] = later + (previous["later"] as? [[String: Any]] ?? []).filter {
                peers.contains($0["host"] as? String ?? "")
            }
        }
        if !counts.isEmpty { model["counts"] = counts }
        return model
    }
}

/// Turns atc's `--json` model into menu lines. Pure, so it is tested with fixtures.
public enum AgentsMenu {
    static let capSize = ["critical": 1, "constrained": 2, "comfortable": 4, "abundant": 8]
    static let urgentKinds: Set<String> = ["blocked", "approval", "amail_approval", "amail_request", "amail_device"]

    public static func build(model: [String: Any]?, error: String?, providers: [[String: Any]],
                             atc: String, webURL: String? = nil, now: Date = Date()) -> (nodes: [MenuNode], badge: Badge?) {
        let webURL = validWebURL(webURL)
        let openWeb = webURL.map { MenuNode("Open atc web", action: .open($0)) }
        guard let model else {
            let status = error.map { "atc: \($0)" } ?? "Reading your agents…"
            return ([.header("Agents"), .header(status.clipped(90)),
                     MenuNode("Open atc…", action: .run([atc, "--open"]))] + [openWeb].compactMap { $0 }, nil)
        }
        let groups = model["groups"] as? [String: Any] ?? [:]
        func group(_ key: String) -> [[String: Any]] { groups[key] as? [[String: Any]] ?? [] }
        let blocked = group("blocked"), waiting = group("waiting"), working = group("working")
        let needs = model["needs"] as? [[String: Any]]
        let counts = model["counts"] as? [String: Any] ?? [:]
        let jobs = model["jobs"] as? [String: [String: Any]] ?? [:]

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
                                action: sid.isEmpty ? nil : .runQuietly(jumpCommand(session, sid: sid, atc: atc)),
                                toolTip: tip.isEmpty ? nil : tip)
            }
            if items.count > limit {
                out.append(MenuNode("     … \(items.count - limit) more in atc", action: .run([atc, "--open"])))
            }
            return out
        }
        if let needs {
            let urgent = needs.filter(isUrgent)
            let other = needs.filter {
                !isUrgent($0) && !["waiting", "later", "job"].contains($0["kind"] as? String ?? "")
            }
            if !urgent.isEmpty || !other.isEmpty || needs.contains(where: { $0["kind"] as? String == "waiting" }) {
                nodes.append(.header("Needs you"))
                nodes += (urgent + other).map { needNode($0, model: model, atc: atc, webURL: webURL) }
            }
            let waitingNeeds = needs.filter { $0["kind"] as? String == "waiting" }
            if !waitingNeeds.isEmpty {
                nodes.append(.header("Waiting on you"))
                nodes += waitingNeeds.prefix(8).map { needNode($0, model: model, atc: atc, webURL: webURL) }
                if waitingNeeds.count > 8 {
                    nodes.append(MenuNode("     … \(waitingNeeds.count - 8) more in atc", action: .run([atc, "--open"])))
                }
            }
        } else {
            if !blocked.isEmpty { nodes += [.header("Blocked on you")] + sessions(blocked, mark: "!", limit: 20) }
            if !waiting.isEmpty { nodes += [.header("Waiting on you")] + sessions(waiting, mark: "◆", limit: 8) }
        }
        if let later = laterNode(model["later"] as? [[String: Any]] ?? [], now: now) {
            nodes.append(later)
        }
        if let jobs = jobsNode(jobs, needs: needs ?? []) { nodes.append(jobs) }
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
        if let openWeb { nodes.append(openWeb) }

        let urgentCount = counts["needs_urgent"] as? Int ?? needs?.filter(isUrgent).count ?? blocked.count
        let listedFailures = jobs.values.flatMap { $0["jobs"] as? [[String: Any]] ?? [] }
            .filter { $0["failing"] as? Bool == true }.count
        let failingCount = counts["jobs_failing"] as? Int
            ?? max(listedFailures, needs?.filter { $0["kind"] as? String == "job" }.count ?? 0)
        let waitingCount = needs?.filter { $0["kind"] as? String == "waiting" }.count ?? waiting.count
        let badge = urgentCount > 0 ? Badge("\(urgentCount)", .alert)
            : failingCount > 0 ? Badge("\(failingCount)", .warn)
            : waitingCount > 0 ? Badge("\(waitingCount)", .warn) : nil
        return (nodes, badge)
    }

    static func validWebURL(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: value), ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty else { return nil }
        return url.absoluteString
    }

    static func isUrgent(_ need: [String: Any]) -> Bool {
        urgentKinds.contains(need["kind"] as? String ?? "")
    }

    static func needNode(_ need: [String: Any], model: [String: Any], atc: String, webURL: String?) -> MenuNode {
        let kind = need["kind"] as? String ?? ""
        let title = (need["title"] as? String ?? "Needs attention").firstLine
        let detail = need["detail"] as? String ?? ""
        let hint = need["hint"] as? String ?? ""
        let host = need["host"] as? String
        let location = host.map { " [\($0)]" } ?? ""
        let tip = [detail, hint].filter { !$0.isEmpty }.joined(separator: " — ")
        if kind == "approval" {
            return MenuNode("Approve in atc web… — \(title.clipped(65))\(location)",
                            action: webURL.map { .open($0) }, isEnabled: webURL != nil,
                            toolTip: webURL == nil ? "Set ATC_WEB_URL to approve in atc web. \(tip)" : tip)
        }
        if kind == "blocked" || kind == "waiting" {
            let sid = need["sid"] as? String ?? ""
            let groups: [String: Any]?
            if let host {
                groups = (model["hosts"] as? [[String: Any]])?.first { $0["host"] as? String == host }?["groups"] as? [String: Any]
            } else {
                groups = model["groups"] as? [String: Any]
            }
            let session = (groups?[kind] as? [[String: Any]])?.first { $0["sid"] as? String == sid }
            let name = session?["name"] as? String ?? title
            let state = session?["state"] as? String
                ?? (need["since"] as? Int).map { "\(kind == "blocked" ? "needs you" : "waiting") \(humanAge(max(0, $0)))" }
            let doing = (session?["doing"] as? String ?? detail).firstLine
            let mark = kind == "blocked" ? "!" : "◆"
            // Remote sessions must go through atc's scan, not a local tty fast path.
            let command = jumpCommand(host == nil ? session ?? [:] : [:], sid: sid, atc: atc)
            return MenuNode("\(mark)  \(name)\(location)\(state.map { " · \($0)" } ?? "") — \(doing)".clipped(100),
                            action: sid.isEmpty ? nil : .runQuietly(command), isEnabled: !sid.isEmpty, toolTip: tip)
        }
        let answer = hint.isEmpty && kind.hasPrefix("amail_") ? "Answer in the a-mail app." : hint.firstLine
        return MenuNode("\(title.clipped(60))\(location)\(answer.isEmpty ? "" : " — \(answer)")", isEnabled: false, toolTip: tip)
    }

    static func laterNode(_ items: [[String: Any]], now: Date) -> MenuNode? {
        let iso = ISO8601DateFormatter()
        let fractionalISO = ISO8601DateFormatter()
        fractionalISO.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let upcoming = items.compactMap { item -> (item: [String: Any], seconds: Int)? in
            let date = (item["when"] as? String).flatMap { iso.date(from: $0) ?? fractionalISO.date(from: $0) }
            guard let seconds = item["in"] as? Double ?? date?.timeIntervalSince(now),
                  seconds.isFinite, seconds >= 0, seconds <= 86_400 else { return nil }
            return (item, Int(seconds))
        }.enumerated().sorted {
            $0.element.seconds == $1.element.seconds ? $0.offset < $1.offset : $0.element.seconds < $1.element.seconds
        }.map(\.element)
        guard !upcoming.isEmpty else { return nil }
        return MenuNode("Later", children: upcoming.map { item, seconds in
            let title = (item["title"] as? String ?? "Scheduled item").firstLine
            let host = (item["host"] as? String).map { " [\($0)]" } ?? ""
            let tip = [item["when"] as? String, item["source"] as? String, item["session"] as? String]
                .compactMap { $0 }.joined(separator: " — ")
            return MenuNode("\(title.clipped(70))\(host) — in \(humanAge(seconds))", isEnabled: false, toolTip: tip)
        })
    }

    static func jobsNode(_ hosts: [String: [String: Any]], needs: [[String: Any]]) -> MenuNode? {
        var hosts = hosts
        // Older peers can forward a failing need without a full jobs snapshot.
        for need in needs where need["kind"] as? String == "job" {
            let host = need["host"] as? String ?? "local"
            let name = need["job"] as? String ?? need["title"] as? String ?? "Job"
            var entry = hosts[host] ?? [:]
            var jobs = entry["jobs"] as? [[String: Any]] ?? []
            if !jobs.contains(where: { $0["name"] as? String == name }) {
                jobs.append(["name": name, "failing": true, "purpose": need["detail"] as? String ?? "",
                             "hasName": need["job"] as? String != nil])
            }
            entry["jobs"] = jobs
            hosts[host] = entry
        }
        guard !hosts.isEmpty else { return nil }
        return MenuNode("Jobs", children: hosts.keys.sorted().map { host in
            let entry = hosts[host] ?? [:]
            let jobs = (entry["jobs"] as? [[String: Any]] ?? []).enumerated().sorted {
                let left = $0.element["failing"] as? Bool == true, right = $1.element["failing"] as? Bool == true
                return left != right ? left : $0.offset < $1.offset
            }.map(\.element)
            var children: [MenuNode] = []
            if entry["ok"] as? Bool == false {
                children.append(.header("⚠︎ \((entry["error"] as? String ?? "unreachable").firstLine.clipped(90)) — last seen"))
            }
            children += jobs.map { job in
                let name = job["name"] as? String ?? ""
                let failing = job["failing"] as? Bool == true
                let state = failing ? "failing" : job["running"] as? Bool == true ? "running" : job["state"] as? String ?? "idle"
                let exit = (job["last_exit"] as? Int).map { " · exit \($0)" } ?? ""
                let canOpen = !name.isEmpty && job["hasName"] as? Bool != false
                return MenuNode("\(failing ? "!" : "●")  \(name.clipped(65)) — \(state)\(exit)",
                                action: canOpen ? .run(jobStatusCommand(name: name, host: host)) : nil,
                                isEnabled: canOpen, toolTip: job["purpose"] as? String)
            }
            if children.isEmpty { children.append(.header("No jobs")) }
            return MenuNode(host, children: children)
        })
    }

    /// Pass the command as an AppleScript argument, and quote each shell word independently.
    /// `run` still owns execution; Terminal keeps the full status output available to read.
    static func jobStatusCommand(name: String, host: String) -> [String] {
        func quote(_ word: String) -> String { "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let argv = ["loom"] + (host == "local" ? [] : ["--host", host]) + ["jobs", "status", name]
        let command = "export PATH=\(quote(Shell.searchPath)); " + argv.map(quote).joined(separator: " ")
        let script = """
        on run argv
            tell application "Terminal"
                activate
                do script (item 1 of argv)
            end tell
        end run
        """
        return ["/usr/bin/osascript", "-e", script, "--", command]
    }

    /// A plain terminal session also passes the tty from the last poll, so atc focuses it in under a
    /// second instead of rescanning everything first (~10 s). Background and herdr sessions need the scan.
    static func jumpCommand(_ session: [String: Any], sid: String, atc: String) -> [String] {
        let tty = session["tty"] as? String ?? ""
        let inHerdr = !(session["herdr"] as? String ?? "").isEmpty
        let plain = session["kind"] as? String == "interactive" && !inHerdr
        return plain && !tty.isEmpty ? [atc, "--jump", sid, "--tty", tty] : [atc, "--jump", sid]
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
