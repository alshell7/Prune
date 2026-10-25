import Foundation

struct ShellResult {
    var status: Int32
    var stdout: String
    var stderr: String
    var timedOut = false
    var ok: Bool { status == 0 && !timedOut }
}

enum Shell {
    /// Apps launched from Finder get a minimal PATH, so developer tools are looked up in the usual places.
    static let searchDirs: [String] = {
        let home = NSHomeDirectory()
        // The user's real PATH from their login shell comes first, so tools resolve exactly as in Terminal.
        var dirs: [String] = loginShellPath()
        let fallback = [
            "/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "/usr/local/sbin",
            "\(home)/.cargo/bin", "\(home)/.local/bin", "/usr/local/go/bin", "\(home)/go/bin",
            "\(home)/.bun/bin", "\(home)/.volta/bin", "\(home)/Library/pnpm", "\(home)/.deno/bin",
            "\(home)/.orbstack/bin", "/Applications/Docker.app/Contents/Resources/bin",
            "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        ]
        for d in fallback where !dirs.contains(d) { dirs.append(d) }
        if let p = ProcessInfo.processInfo.environment["PATH"] {
            for d in p.split(separator: ":").map(String.init) where !dirs.contains(d) { dirs.append(d) }
        }
        return dirs
    }()

    static var searchPath: String { searchDirs.joined(separator: ":") }

    private static func loginShellPath() -> [String] {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = ["-lc", "printf %s \"$PATH\""]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let deadline = Date().addingTimeInterval(4)
        while p.isRunning && Date() < deadline { usleep(20_000) }
        if p.isRunning { p.terminate(); return [] }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        var seen = Set<String>()
        return text.split(separator: ":").map(String.init).filter { $0.hasPrefix("/") && seen.insert($0).inserted }
    }

    /// Every executable with this name on the search path (e.g. Homebrew node and a pkg-installed node).
    static func whichAll(_ name: String) -> [String] {
        var seen = Set<String>()
        return searchDirs.map { "\($0)/\(name)" }.filter {
            FileManager.default.isExecutableFile(atPath: $0) && seen.insert(URL(fileURLWithPath: $0).resolvingSymlinksInPath().path).inserted
        }
    }

    private static var toolCache: [String: String?] = [:]
    private static let lock = NSLock()

    /// Absolute path of a CLI tool, or nil when it isn't installed.
    static func which(_ name: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        if let cached = toolCache[name] { return cached }
        var found: String?
        for dir in searchDirs {
            let p = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: p) { found = p; break }
        }
        toolCache[name] = found
        return found
    }

    @discardableResult
    static func run(_ tool: String, _ args: [String], cwd: String? = nil, timeout: TimeInterval = 60) -> ShellResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = searchPath
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_OPTIONAL_LOCKS"] = "0"      // never block a running git/IDE
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        env["HOMEBREW_NO_ENV_HINTS"] = "1"
        env["NO_COLOR"] = "1"
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice

        do { try p.run() } catch {
            return ShellResult(status: -1, stdout: "", stderr: error.localizedDescription)
        }

        final class Box { var data = Data() }
        let o = Box(), e = Box()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async { o.data = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter()
        DispatchQueue.global(qos: .utility).async { e.data = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }

        var timedOut = false
        if group.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            p.terminate()
            if group.wait(timeout: .now() + 3) == .timedOut { kill(p.processIdentifier, SIGKILL) }
            group.wait()
        }
        p.waitUntilExit()
        return ShellResult(status: p.terminationStatus,
                           stdout: String(decoding: o.data, as: UTF8.self),
                           stderr: String(decoding: e.data, as: UTF8.self),
                           timedOut: timedOut)
    }

    static func quoteIfNeeded(_ s: String) -> String {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_./=:@+%,"))
        if !s.isEmpty && s.unicodeScalars.allSatisfy({ safe.contains($0) }) { return s }
        return shellQuote(s)
    }

    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Runs a shell command line as root through the standard macOS administrator prompt.
    static func runAsAdmin(_ commandLine: String) -> ShellResult {
        let escaped = commandLine
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\(escaped)\" with administrator privileges"
        var errorInfo: NSDictionary?
        var output = ""
        let work = {
            let script = NSAppleScript(source: source)
            let result = script?.executeAndReturnError(&errorInfo)
            output = result?.stringValue ?? ""
        }
        if Thread.isMainThread { work() } else { DispatchQueue.main.sync(execute: work) }
        if let errorInfo {
            let msg = errorInfo[NSAppleScript.errorMessage] as? String ?? "Administrator command failed"
            return ShellResult(status: 1, stdout: output, stderr: msg)
        }
        return ShellResult(status: 0, stdout: output, stderr: "")
    }
}
