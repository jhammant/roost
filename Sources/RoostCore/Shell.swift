import Foundation

/// Runs command-line tools from a menu-bar app. Apps launched from the Finder or
/// at login get a bare PATH (/usr/bin:/bin:…), so Homebrew and ~/.local/bin are
/// added; without them `atc` can't find `claude` or `quotamax`.
public enum Shell {
    public static let searchPath: String = {
        let home = NSHomeDirectory()
        let wanted = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        let current = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        var seen = Set<String>()
        return (wanted + current).filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: ":")
    }()

    public struct Result {
        public let status: Int32
        public let stdout: Data
        public let stderr: String
        public let launchError: String?
        public var ok: Bool { launchError == nil && status == 0 }
        public var output: String { String(decoding: stdout, as: UTF8.self) }

        /// The most useful line to show someone: stdout's first line, else stderr's, else why it failed.
        public var summary: String {
            if let launchError { return launchError }
            let out = output.firstLine
            if !out.isEmpty { return out }
            let err = stderr.firstLine
            return err.isEmpty ? (status == 0 ? "" : "exited \(status)") : err
        }
    }

    public static func which(_ name: String) -> String? {
        if name.contains("/") { return FileManager.default.isExecutableFile(atPath: name) ? name : nil }
        for dir in searchPath.split(separator: ":") {
            let candidate = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    public static func run(_ argv: [String], timeout: TimeInterval = 30) -> Result {
        guard let first = argv.first, let executable = which(first) else {
            return Result(status: -1, stdout: Data(), stderr: "", launchError: "\(argv.first ?? "?") not found")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(argv.dropFirst())
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = searchPath
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err

        // Drain both pipes while the process runs: a large --json would otherwise
        // fill the pipe buffer and deadlock the child.
        var outData = Data()
        var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            outData = out.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            errData = err.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        do {
            try process.run()
        } catch {
            out.fileHandleForWriting.closeFile()
            err.fileHandleForWriting.closeFile()
            return Result(status: -1, stdout: Data(), stderr: "", launchError: error.localizedDescription)
        }
        let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        process.waitUntilExit()
        timer.cancel()
        group.wait()
        let timedOut = process.terminationReason == .uncaughtSignal && process.terminationStatus == SIGTERM
        return Result(status: process.terminationStatus, stdout: outData,
                      stderr: String(decoding: errData, as: UTF8.self),
                      launchError: timedOut ? "\(first) timed out after \(Int(timeout))s" : nil)
    }
}
