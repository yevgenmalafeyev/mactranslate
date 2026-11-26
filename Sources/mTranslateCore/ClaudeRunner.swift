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
    public var model: ClaudeModel
    public var system: String
    public var user: String
    public var effort: String?

    public init(model: ClaudeModel, system: String, user: String, effort: String? = nil) {
        self.model = model; self.system = system; self.user = user; self.effort = effort
    }

    /// Flags for every claude call. The model only ever turns text into text here, and the text it reads
    /// is untrusted (anything the user selected, or a link supplied), so it gets no tools, no MCP servers,
    /// no slash commands or skills, no user/project settings, hooks or plugins, and leaves no session files.
    /// `system` must be app-written text only; user data goes in through standard input, never the command line.
    public static func arguments(model: ClaudeModel, system: String, effort: String? = nil) -> [String] {
        var a = ["-p", "--model", model.rawValue,
                 "--safe-mode",
                 "--restricted",
                 "--strict-mcp-config",
                 "--disable-slash-commands",
                 "--no-session-persistence",
                 "--permission-mode", "dontAsk",
                 "--tools", "",
                 "--setting-sources", "",
                 "--input-format", "stream-json",
                 "--output-format", "stream-json",
                 "--include-partial-messages",
                 "--verbose"]
        if let effort { a += ["--effort", effort] }
        a += ["--system-prompt", system]
        return a
    }

    public var arguments: [String] { Self.arguments(model: model, system: system, effort: effort) }

    /// One user turn in the CLI's stream-json input format (a single line).
    static func userMessage(_ content: String) -> Data? {
        let msg: [String: Any] = ["type": "user", "message": ["role": "user", "content": content]]
        guard var data = try? JSONSerialization.data(withJSONObject: msg) else { return nil }
        data.append(0x0A)
        return data
    }
}

/// Thread-safe byte line splitter.
final class LineBuffer: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()

    func append(_ d: Data) -> [String] {
        lock.lock(); defer { lock.unlock() }
        data.append(d)
        // A line this long is not a CLI event: drop it instead of growing without bound.
        if data.count > 8 << 20, data.firstIndex(of: 0x0A) == nil { data.removeAll() }
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

public struct ClaudeRunner: Sendable {
    public init() {}

    /// A one-shot call may not run longer than this; then it is stopped with everything it started.
    static let timeout: TimeInterval = 120

    public func stream(_ req: ClaudeRequest) -> AsyncThrowingStream<ClaudeEvent, Error> {
        AsyncThrowingStream { cont in
            guard let binary = Tools.claude else { cont.finish(throwing: ClaudeError.cliNotFound); return }
            guard let message = ClaudeRequest.userMessage(req.user) else {
                cont.finish(throwing: ClaudeError.malformedOutput); return
            }
            let lines = LineBuffer()
            let stderr = StderrBuffer()
            do {
                let child = try Tools.start(binary, req.arguments, timeout: Self.timeout,
                    onOutput: { d in
                        for l in lines.append(d) { if let ev = ClaudeEvent.decode(l) { cont.yield(ev) } }
                    },
                    onError: { stderr.append($0) },
                    onExit: { status in
                        if let ev = ClaudeEvent.decode(lines.flush()) { cont.yield(ev) }
                        if status != 0 {
                            cont.finish(throwing: ClaudeError.classify(status: status, text: stderr.text))
                        } else {
                            cont.finish()
                        }
                    })
                child.write(message)
                child.closeInput()
                cont.onTermination = { reason in
                    if case .cancelled = reason { child.terminate() }
                }
            } catch {
                cont.finish(throwing: ClaudeError.failed(status: -1, detail: error.localizedDescription))
            }
        }
    }
}
