import Foundation

public enum ClaudeEvent: Sendable, Equatable {
    case text(String)
    case full(String)
    case rateLimit(status: String, resetsAt: Date?, utilization: Double?)
    case result(isError: Bool, message: String?)

    static func decode(_ line: String) -> ClaudeEvent? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String
        else { return nil }
        switch type {
        case "stream_event":
            guard let ev = obj["event"] as? [String: Any],
                  ev["type"] as? String == "content_block_delta",
                  let delta = ev["delta"] as? [String: Any],
                  delta["type"] as? String == "text_delta",
                  let text = delta["text"] as? String
            else { return nil }
            return .text(text)
        case "assistant":
            guard let msg = obj["message"] as? [String: Any],
                  let content = msg["content"] as? [[String: Any]]
            else { return nil }
            let text = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
            return text.isEmpty ? nil : .full(text)
        case "rate_limit_event":
            let info = obj["rate_limit_info"] as? [String: Any] ?? [:]
            let status = info["status"] as? String ?? "unknown"
            let resets = (info["resetsAt"] as? Double).map { Date(timeIntervalSince1970: $0) }
            return .rateLimit(status: status, resetsAt: resets, utilization: info["utilization"] as? Double)
        case "result":
            return .result(isError: obj["is_error"] as? Bool ?? false, message: obj["result"] as? String)
        default:
            return nil
        }
    }
}

public struct ClaudeRequest: Sendable {
    public var binary: URL
    public var model: ClaudeModel
    public var system: String
    public var user: String
    public var effort: String?

    public init(binary: URL, model: ClaudeModel, system: String, user: String, effort: String? = nil) {
        self.binary = binary; self.model = model; self.system = system; self.user = user; self.effort = effort
    }

    public var arguments: [String] {
        var a = ["-p", "--model", model.rawValue,
                 "--tools", "",
                 "--strict-mcp-config",
                 "--setting-sources", "",
                 "--disable-slash-commands",
                 "--no-session-persistence",
                 "--output-format", "stream-json",
                 "--include-partial-messages",
                 "--verbose"]
        if let effort { a += ["--effort", effort] }
        a += ["--system-prompt", system, user]
        return a
    }
}

/// Thread-safe byte line splitter.
final class LineBuffer: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()

    func append(_ d: Data) -> [String] {
        lock.lock(); defer { lock.unlock() }
        data.append(d)
        var lines: [String] = []
        while let nl = data.firstIndex(of: 0x0A) {
            let lineData = data[data.startIndex..<nl]
            lines.append(String(decoding: lineData, as: UTF8.self))
            data.removeSubrange(data.startIndex...nl)
        }
        return lines
    }

    func flush() -> String {
        lock.lock(); defer { lock.unlock() }
        let s = String(decoding: data, as: UTF8.self)
        data.removeAll()
        return s
    }
}

final class StderrBuffer: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()
    func append(_ d: Data) { lock.lock(); if data.count < 64_000 { data.append(d) }; lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}

final class ProcessBox: @unchecked Sendable {
    let process = Process()
}

public struct ClaudeRunner: Sendable {
    public init() {}

    static func environment(for binary: URL) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let extra = [binary.deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        env["PATH"] = (extra + [env["PATH"] ?? ""]).joined(separator: ":")
        return env
    }

    static var workingDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("mTranslate", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support
    }

    public func stream(_ req: ClaudeRequest) -> AsyncThrowingStream<ClaudeEvent, Error> {
        AsyncThrowingStream { cont in
            let box = ProcessBox()
            let p = box.process
            let out = Pipe(), err = Pipe()
            p.executableURL = req.binary
            p.arguments = req.arguments
            p.standardInput = FileHandle.nullDevice
            p.standardOutput = out
            p.standardError = err
            p.environment = Self.environment(for: req.binary)
            p.currentDirectoryURL = Self.workingDirectory

            let q = DispatchQueue(label: "claude.runner.output")
            let lines = LineBuffer()
            let stderr = StderrBuffer()
            let group = DispatchGroup()
            group.enter() // stdout EOF
            group.enter() // stderr EOF
            group.enter() // termination

            out.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                if d.isEmpty {
                    h.readabilityHandler = nil
                    q.async {
                        let rest = lines.flush()
                        if let ev = ClaudeEvent.decode(rest) { cont.yield(ev) }
                        group.leave()
                    }
                    return
                }
                let ls = lines.append(d)
                q.async { for l in ls { if let ev = ClaudeEvent.decode(l) { cont.yield(ev) } } }
            }
            err.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                if d.isEmpty { h.readabilityHandler = nil; group.leave(); return }
                stderr.append(d)
            }
            p.terminationHandler = { _ in group.leave() }

            group.notify(queue: q) {
                let status = box.process.terminationStatus
                if status != 0 {
                    cont.finish(throwing: ClaudeError.classify(status: status, text: stderr.text))
                } else {
                    cont.finish()
                }
            }

            do {
                try p.run()
            } catch {
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                cont.finish(throwing: ClaudeError.cliNotFound)
                return
            }

            cont.onTermination = { reason in
                if case .cancelled = reason, box.process.isRunning {
                    box.process.terminate()
                    let pid = box.process.processIdentifier
                    DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                        if box.process.isRunning { kill(pid, SIGKILL) }
                    }
                }
            }
        }
    }
}
