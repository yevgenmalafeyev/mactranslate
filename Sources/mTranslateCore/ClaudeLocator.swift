import Foundation

public enum ClaudeLocator {
    /// Resolve the claude binary: explicit setting -> well-known paths -> login-shell lookup.
    public static func locate(configured: String?) -> URL? {
        let fm = FileManager.default
        if let c = configured?.trimmingCharacters(in: .whitespaces), !c.isEmpty {
            let path = (c as NSString).expandingTildeInPath
            if fm.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        }
        let home = fm.homeDirectoryForCurrentUser.path
        for p in ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude", "\(home)/.claude/local/claude"] {
            if fm.isExecutableFile(atPath: p) { return URL(fileURLWithPath: p) }
        }
        return shellLookup()
    }

    static func shellLookup() -> URL? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lic", "command -v claude"]
        p.standardInput = FileHandle.nullDevice
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(5)
        while p.isRunning && Date() < deadline { usleep(50_000) }
        if p.isRunning { p.terminate(); return nil }
        let s = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard let line = s.split(separator: "\n").map(String.init).last(where: { $0.hasPrefix("/") }),
              FileManager.default.isExecutableFile(atPath: line)
        else { return nil }
        return URL(fileURLWithPath: line)
    }
}
