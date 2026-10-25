import Foundation

/// Last line of defence: every path is checked here right before anything is removed,
/// regardless of what a scanner suggested. Returns a reason when a path must not be touched.
enum SafetyGuard {
    private static let home = FS.home.path

    /// Exact paths that are never removed (their children may be).
    private static let protectedExact: Set<String> = {
        let h = NSHomeDirectory()
        var s: Set<String> = [
            "/", "/System", "/Library", "/Applications", "/Users", "/usr", "/usr/local", "/usr/local/bin",
            "/bin", "/sbin", "/etc", "/var", "/private", "/private/var", "/private/etc", "/private/tmp",
            "/opt", "/opt/homebrew", "/opt/homebrew/bin", "/Volumes", "/cores", "/dev", "/tmp",
            "/Library/Caches", "/Library/Logs", "/Library/LaunchAgents", "/Library/LaunchDaemons",
            "/Library/Developer", "/Library/Java", "/Library/Java/JavaVirtualMachines", "/Library/Frameworks",
        ]
        for sub in ["", "/Library", "/Library/Caches", "/Library/Application Support", "/Library/Containers",
                    "/Library/Group Containers", "/Library/Preferences", "/Library/Logs", "/Library/Developer",
                    "/Library/Developer/Xcode", "/Library/Developer/CoreSimulator", "/Library/LaunchAgents",
                    "/Library/Android", "/Library/Android/sdk", "/Documents", "/Desktop", "/Downloads",
                    "/Pictures", "/Movies", "/Music", "/Public", "/Applications", "/Developer", "/Projects",
                    "/.Trash", "/.cache", "/.config", "/.local", "/.local/share", "/.npm", "/.cargo", "/.rustup",
                    "/.gradle", "/.android", "/go", "/go/pkg", "/.nvm", "/.pyenv", "/.docker", "/.ssh"] {
            s.insert(h + sub)
        }
        return s
    }()

    /// Any path containing one of these components is off-limits.
    private static let forbiddenComponents: Set<String> = [
        "Keychains", ".ssh", ".gnupg", "Mobile Documents", "CloudStorage", "com.apple.TCC",
        ".aws", ".kube", ".password-store", "1Password", "Accounts",
    ]

    /// Only these system-level areas may ever be touched (with admin), everything else outside home is refused.
    private static let systemAllowPrefixes = [
        "/Library/Caches/", "/Library/Logs/", "/Library/LaunchAgents/", "/Library/LaunchDaemons/",
        "/Library/Developer/CoreSimulator/Caches/", "/Library/Java/JavaVirtualMachines/",
        "/Library/Frameworks/Python.framework/Versions/", "/usr/local/bin/", "/opt/homebrew/bin/",
        "/Applications/", "/Users/Shared/",
    ]

    private static let userTemp: String = {
        let t = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().path
        return t.hasSuffix("/") ? t : t + "/"
    }()

    static func check(_ url: URL, allowAppBundle: Bool = false) -> String? {
        let raw = url.standardizedFileURL.path
        guard raw.hasPrefix("/"), raw.count > 1 else { return "Not an absolute path" }

        // Resolve symlinks in parent folders (not the item itself — removing a symlink removes only the link).
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().path
        let path = (parent as NSString).appendingPathComponent(url.lastPathComponent)

        if protectedExact.contains(path) || protectedExact.contains(raw) { return "Protected location" }

        let comps = Set(path.split(separator: "/").map(String.init))
        if let bad = comps.first(where: { forbiddenComponents.contains($0) }) { return "Path contains protected folder \u{201C}\(bad)\u{201D}" }
        if path.contains(".photoslibrary") || path.hasPrefix(home + "/Library/Mail") || path.hasPrefix(home + "/Library/Messages") {
            return "Personal library data is never touched"
        }
        if path.split(separator: "/").contains(".git") { return "Inside a .git directory. Use git to manage it." }
        if path.hasPrefix("/System/") || path.hasPrefix("/usr/") && !path.hasPrefix("/usr/local/bin/") { return "System location" }

        if path.hasPrefix(home + "/") {
            let rel = path.dropFirst(home.count + 1)
            let depth = rel.split(separator: "/").count
            if depth < 2 { return "Top-level home folders are never removed" }
            if rel.hasPrefix("Library/"), depth < 3 { return "Top-level Library folders are never removed" }
        } else if path.hasPrefix("/Volumes/") {
            let depth = path.split(separator: "/").count
            if depth < 3 { return "Volume roots are never removed" }
        } else if path.hasPrefix(userTemp), path.count > userTemp.count {
            // Per-user temp folder ($TMPDIR): children only.
        } else if path == "/Library/Developer/CommandLineTools" {
            // Allowed only as a whole, and only when Xcode provides the toolchain (checked by the scanner).
        } else if !systemAllowPrefixes.contains(where: { path.hasPrefix($0) }) {
            return "Outside the areas Prune is allowed to clean"
        }

        if path.hasPrefix("/Applications/") || path.hasPrefix(home + "/Applications/") {
            let rel = path.hasPrefix("/Applications/") ? String(path.dropFirst("/Applications/".count)) : String(path.dropFirst(home.count + "/Applications/".count))
            let isBundle = rel.hasSuffix(".app") && !rel.dropLast(4).contains(".app/")
            if !(allowAppBundle && isBundle) { return "Inside an application bundle" }
        }

        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
            if let vals = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isVolumeKey]), vals.isVolume == true {
                return "Mount point"
            }
            // A folder that is itself a git repository (not a linked worktree) is source code, not junk.
            let dotGit = (path as NSString).appendingPathComponent(".git")
            var gitIsDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: dotGit, isDirectory: &gitIsDir), gitIsDir.boolValue {
                return "Contains a git repository"
            }
        }
        return nil
    }
}
