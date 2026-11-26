import Foundation

/// Locates and starts the local `claude` command-line tool.
///
/// The tool is looked up only in a fixed list of install locations: never through a setting, a shell or
/// the inherited PATH, because any program can change those. And it is always started without this app's
/// privacy permissions (see `disclaim`), so even a fake `claude` planted in one of those folders cannot
/// read the keyboard through this app's Input Monitoring permission.
public enum Tools {
    static let searchPaths: [String] = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // The legacy Claude Code location comes last, so it can't shadow a regular install.
        return ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "\(home)/.claude/local"]
    }()

    /// The tool's real file (symlinks resolved), shown in Configuration so the user can see what runs.
    public static func find(_ name: String) -> URL? {
        for dir in searchPaths {
            let path = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path).resolvingSymlinksInPath()
            }
        }
        return nil
    }

    public static var claude: URL? { find("claude") }

    /// Only what the tool needs; the rest of this app's environment is not passed on
    /// (it could carry e.g. an API endpoint override set by another program via `launchctl setenv`).
    static var environment: [String: String] {
        let mine = ProcessInfo.processInfo.environment
        var env: [String: String] = [:]
        for key in ["USER", "LOGNAME", "TMPDIR", "LANG", "__CF_USER_TEXT_ENCODING"] { env[key] = mine[key] }
        env["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        env["PATH"] = (searchPaths + ["/usr/sbin", "/sbin"]).joined(separator: ":")
        return env
    }

    /// An empty private folder the tool runs in, so it finds no project files (CLAUDE.md, .mcp.json, …)
    /// and is not started next to the history database.
    static var workingDirectory: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("mTranslate", isDirectory: true)
            .appendingPathComponent("cli", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return dir
    }

    /// Makes the spawned program responsible for itself in the eyes of macOS privacy protection (TCC).
    /// Without it a child counts as part of this app and silently gets its Input Monitoring permission.
    /// (System function without a public header; also used by browsers and Xcode for the same purpose.)
    private typealias Disclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32
    private static let disclaim: Disclaim? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim")
        else { return nil }
        return unsafeBitCast(sym, to: Disclaim.self)
    }()

    public struct SpawnError: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// A running tool: its own process group, three pipes, a deadline.
    public final class Child: @unchecked Sendable {
        public let pid: pid_t
        private let stdinFD: Int32
        private let lock = NSLock()
        /// Guards the input pipe only, so a write stuck on a tool that doesn't read can't block stopping it.
        private let writeLock = NSLock()
        private var exited = false
        private var inputClosed = false
        private var deadline: DispatchWorkItem?

        fileprivate init(pid: pid_t, stdinFD: Int32) {
            self.pid = pid
            self.stdinFD = stdinFD
        }

        /// Writes to the tool's standard input. Returns false if the tool is gone or the pipe is closed.
        @discardableResult
        public func write(_ data: Data) -> Bool {
            writeLock.lock(); defer { writeLock.unlock() }
            lock.lock(); let closed = inputClosed; lock.unlock()
            guard !closed else { return false }
            return data.withUnsafeBytes { buf -> Bool in
                var off = 0
                while off < buf.count {
                    let n = Darwin.write(stdinFD, buf.baseAddress! + off, buf.count - off)
                    if n > 0 { off += n } else if n == -1, errno == EINTR { continue } else { return false }
                }
                return true
            }
        }

        public func closeInput() {
            lock.lock()
            let already = inputClosed
            inputClosed = true
            lock.unlock()
            guard !already else { return }
            writeLock.lock(); defer { writeLock.unlock() }
            close(stdinFD)
        }

        public var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return !exited }

        /// Asks the tool's whole process group to stop, then forces it. Nothing is signalled after the
        /// child was collected (its id could then belong to another program).
        public func terminate(grace: TimeInterval = 1) {
            lock.lock(); defer { lock.unlock() }
            guard !exited else { return }
            // The group, and the tool itself in case it left the group.
            kill(-pid, SIGTERM); kill(pid, SIGTERM)
            DispatchQueue.global().asyncAfter(deadline: .now() + grace) { [self] in
                lock.lock(); defer { lock.unlock() }
                if !exited { kill(-pid, SIGKILL); kill(pid, SIGKILL) }
            }
        }

        /// Stops it at once (used when the app quits).
        fileprivate func killNow() {
            lock.lock(); defer { lock.unlock() }
            if !exited { kill(-pid, SIGKILL); kill(pid, SIGKILL) }
        }

        fileprivate func arm(timeout: TimeInterval) {
            let item = DispatchWorkItem { [weak self] in self?.terminate(grace: 5) }
            lock.lock(); deadline = item; lock.unlock()
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: item)
        }

        fileprivate func markExited() {
            lock.lock(); exited = true; deadline?.cancel(); deadline = nil; lock.unlock()
        }
    }

    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var running: [pid_t: Child] = [:]

    /// Stops every tool this app started, immediately. Called when the app quits, so nothing keeps
    /// running (and using the account) after it.
    public static func killAll() {
        registryLock.lock(); let all = Array(running.values); registryLock.unlock()
        all.forEach { $0.killNow() }
    }

    /// Starts a tool. `onOutput` / `onError` get chunks as they arrive; `onExit` is called once, after
    /// both streams ended, with the exit status (negative = killed by that signal).
    /// The tool is stopped (with everything it started) when `timeout` passes.
    public static func start(_ tool: URL, _ args: [String], timeout: TimeInterval,
                             onOutput: @escaping @Sendable (Data) -> Void,
                             onError: @escaping @Sendable (Data) -> Void,
                             onExit: @escaping @Sendable (Int32) -> Void) throws -> Child {
        let name = tool.lastPathComponent
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        // The child gets only the three pipes below, no other open files of this app, and default
        // signal handling (a child that inherited blocked signals could not be stopped).
        var noSignals = sigset_t(), allSignals = sigset_t()
        sigemptyset(&noSignals)
        sigfillset(&allSignals)
        posix_spawnattr_setsigmask(&attr, &noSignals)
        posix_spawnattr_setsigdefault(&attr, &allSignals)
        // Its own process group, so stopping it also stops helpers it started.
        posix_spawnattr_setpgroup(&attr, 0)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF
                                              | POSIX_SPAWN_SETPGROUP))
        // Never run a tool with this app's permissions: if they can't be dropped, don't run it.
        guard let disclaim, disclaim(&attr, 1) == 0 else {
            throw SpawnError(message: "\(name): could not start it without this app's permissions")
        }

        var inp: [Int32] = [-1, -1], out: [Int32] = [-1, -1], err: [Int32] = [-1, -1]
        guard pipe(&inp) == 0, pipe(&out) == 0, pipe(&err) == 0 else {
            for fd in inp + out + err where fd >= 0 { close(fd) }
            throw SpawnError(message: "\(name): could not create pipes")
        }
        // A tool that exits early closes its end; writing to it must fail, not kill this app.
        _ = fcntl(inp[1], F_SETNOSIGPIPE, 1)
        for fd in [inp[1], out[0], err[0]] { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, inp[0], 0)
        posix_spawn_file_actions_adddup2(&actions, out[1], 1)
        posix_spawn_file_actions_adddup2(&actions, err[1], 2)
        posix_spawn_file_actions_addchdir_np(&actions, workingDirectory.path)

        var argv: [UnsafeMutablePointer<CChar>?] = ([tool.path] + args).map { strdup($0) } + [nil]
        var envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { for p in argv + envp { free(p) } }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, tool.path, &actions, &attr, &argv, &envp)
        // Close this app's copies of the child's ends, so reads finish when the child exits.
        close(inp[0]); close(out[1]); close(err[1])
        guard rc == 0 else {
            close(inp[1]); close(out[0]); close(err[0])
            throw SpawnError(message: "\(name): could not start: " + String(cString: strerror(rc)))
        }

        let child = Child(pid: pid, stdinFD: inp[1])
        registryLock.lock(); running[pid] = child; registryLock.unlock()
        let streams = DispatchGroup()
        func pump(_ fd: Int32, _ sink: @escaping @Sendable (Data) -> Void) {
            streams.enter()
            Thread.detachNewThread {
                var buf = [UInt8](repeating: 0, count: 16_384)
                while true {
                    let n = read(fd, &buf, buf.count)
                    if n > 0 { sink(Data(buf[0..<n])) } else if n == -1, errno == EINTR { continue } else { break }
                }
                close(fd)
                streams.leave()
            }
        }
        pump(out[0], onOutput)
        pump(err[0], onError)
        child.arm(timeout: timeout)

        Thread.detachNewThread {
            // Wait without collecting, mark it exited, and only then collect.
            var info = siginfo_t()
            while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) == -1, errno == EINTR {}
            child.markExited()
            registryLock.lock(); running[pid] = nil; registryLock.unlock()
            var status: Int32 = 0
            while waitpid(pid, &status, 0) == -1, errno == EINTR {}
            child.closeInput()
            // A helper that outlived the tool can keep the pipes open: stop what is left of the group
            // (the group id stays taken while any member is alive, so this can't hit another program
            // unless every member is already gone, in which case the pipes would have closed).
            if streams.wait(timeout: .now() + 2) == .timedOut {
                kill(-pid, SIGKILL)
                _ = streams.wait(timeout: .now() + 5)
            }
            let signal = status & 0x7f
            onExit(signal == 0 ? (status >> 8) & 0xff : -signal)
        }
        return child
    }
}
