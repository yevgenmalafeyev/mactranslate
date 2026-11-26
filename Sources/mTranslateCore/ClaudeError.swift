import Foundation

public enum ClaudeError: Error, Equatable, Sendable, LocalizedError {
    case cliNotFound
    case notLoggedIn
    case rateLimited(resetsAt: Date?)
    case timeout
    case malformedOutput
    case failed(status: Int32, detail: String)

    public var errorDescription: String? {
        switch self {
        case .cliNotFound:
            "Claude CLI not found. Set its path in Configuration."
        case .notLoggedIn:
            "Claude CLI is not logged in. Run `claude` in Terminal and log in."
        case .rateLimited(let d):
            if let d {
                "Claude usage limit reached. Resets \(d.formatted(date: .abbreviated, time: .shortened))."
            } else {
                "Claude usage limit reached."
            }
        case .timeout:
            "Claude took too long to answer."
        case .malformedOutput:
            "Claude's answer could not be parsed."
        case .failed(let status, let detail):
            "Claude CLI failed (exit \(status)). \(detail)"
        }
    }

    public var isRetryable: Bool {
        switch self {
        case .cliNotFound, .notLoggedIn: false
        default: true
        }
    }

    /// Classify a failure from exit status plus stderr / result text.
    public static func classify(status: Int32, text: String) -> ClaudeError {
        let t = text.lowercased()
        if t.contains("not logged in") || t.contains("/login") || t.contains("invalid api key") || t.contains("oauth token") {
            return .notLoggedIn
        }
        if t.contains("rate limit") || t.contains("usage limit") || t.contains("limit reached") || t.contains("rate_limit") || t.contains("hit your limit") {
            return .rateLimited(resetsAt: nil)
        }
        let tail = text.split(separator: "\n").suffix(3).joined(separator: " ")
        return .failed(status: status, detail: String(tail.prefix(300)))
    }
}
