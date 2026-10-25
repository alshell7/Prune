import Foundation

/// Which projects pin a given version, and when the most recent of them was active.
struct Usage {
    var projects: Set<String> = []
    var latest: Date?

    mutating func add(_ project: String, _ activity: Date?) {
        projects.insert(project)
        if let a = activity, a > (latest ?? .distantPast) { latest = a }
    }

    var list: String {
        let names = projects.sorted()
        return names.count > 3 ? names.prefix(3).joined(separator: ", ") + " +\(names.count - 3) more" : names.joined(separator: ", ")
    }
}

/// Versions your projects actually require, parsed from build files found during the project walk.
struct Requirements {
    var ndk: [String: Usage] = [:]
    var compileSdk: [String: Usage] = [:]
    var buildTools: [String: Usage] = [:]
    var gradle: [String: Usage] = [:]
    var rust: [String: Usage] = [:]
    var go: [String: Usage] = [:]
    var node: [String: Usage] = [:]
    var python: [String: Usage] = [:]
    var java: [String: Usage] = [:]
    var ruby: [String: Usage] = [:]
    var flutter: [String: Usage] = [:]
    var dotnet: [String: Usage] = [:]
    var pythonHomes: [String: Usage] = [:]
    var unpinnedNativeAndroid = Usage()   // native Android builds that rely on the default/newest NDK

    static func captures(_ pattern: String, _ text: String, options: NSRegularExpression.Options = [.anchorsMatchLines]) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            m.numberOfRanges > 1 && m.range(at: 1).location != NSNotFound ? ns.substring(with: m.range(at: 1)) : nil
        }
    }

    static func build(_ idx: ProjectIndex) -> Requirements {
        var r = Requirements()
        func who(_ file: URL) -> (String, Date?) { (idx.projectName(file.path), idx.activity(for: file)) }

        let gradleFiles = (idx.files["build.gradle"] ?? []) + (idx.files["build.gradle.kts"] ?? [])
            + (idx.files["gradle.properties"] ?? []) + (idx.files["libs.versions.toml"] ?? [])
        for f in gradleFiles {
            guard let t = FS.readText(f, limit: 256 * 1024) else { continue }
            let (p, a) = who(f)
            for v in captures(#"ndkVersion\s*[=:]?\s*["']([0-9][0-9.]+)["']"#, t) { r.ndk[v, default: Usage()].add(p, a) }
            for v in captures(#"compileSdk(?:Version)?\s*[=:]?\s*["']?(?:android-)?(\d{2})"#, t) { r.compileSdk[v, default: Usage()].add(p, a) }
            for v in captures(#"buildToolsVersion\s*[=:]?\s*["']([0-9.]+)["']"#, t) { r.buildTools[v, default: Usage()].add(p, a) }
            for v in captures(#"JavaVersion\.VERSION_(?:1_)?(\d+)"#, t) + captures(#"jvmToolchain\((\d+)\)"#, t)
                + captures(#"JavaLanguageVersion\.of\((\d+)\)"#, t) + captures(#"jvmTarget\s*=\s*["'](?:1\.)?(\d+)["']"#, t) {
                r.java[v, default: Usage()].add(p, a)
            }
            let native = t.contains("externalNativeBuild") || t.contains("ndk {") || t.contains("ndk{") || t.contains("rust {")
                || f.path.contains("/src-tauri/gen/android/")
            if native && captures(#"ndkVersion\s*[=:]?\s*["']([0-9.]+)["']"#, t).isEmpty && !t.contains("ext.ndkVersion") {
                r.unpinnedNativeAndroid.add(p, a)
            }
            if t.contains("flutter.ndkVersion") { r.unpinnedNativeAndroid.add(p, a) }
        }

        // React Native / Expo: versions come from react-native's own version catalog.
        for (path, proj) in idx.projects where proj.markers.contains("package.json") {
            let toml = proj.root.appendingPathComponent("node_modules/react-native/gradle/libs.versions.toml")
            guard let t = FS.readText(toml, limit: 64 * 1024) else { continue }
            let p = idx.projectName(path), a = idx.activity(for: proj.root)
            for v in captures(#"^ndkVersion\s*=\s*"([0-9.]+)""#, t) { r.ndk[v, default: Usage()].add(p + " (React Native)", a) }
            for v in captures(#"^compileSdk\s*=\s*"(\d+)""#, t) { r.compileSdk[v, default: Usage()].add(p + " (React Native)", a) }
            for v in captures(#"^buildTools\s*=\s*"([0-9.]+)""#, t) { r.buildTools[v, default: Usage()].add(p + " (React Native)", a) }
        }

        for f in idx.files["gradle-wrapper.properties"] ?? [] {
            guard let t = FS.readText(f, limit: 16 * 1024) else { continue }
            let (p, a) = who(f)
            for v in captures(#"gradle-([0-9][0-9A-Za-z.\-]*?)-(?:bin|all)\.zip"#, t) { r.gradle[v, default: Usage()].add(p, a) }
        }
        for name in ["rust-toolchain", "rust-toolchain.toml"] {
            for f in idx.files[name] ?? [] {
                guard let t = FS.readText(f, limit: 8 * 1024) else { continue }
                let (p, a) = who(f)
                var ch = captures(#"channel\s*=\s*"([^"]+)""#, t)
                if ch.isEmpty, name == "rust-toolchain", let first = t.split(separator: "\n").first { ch = [first.trimmingCharacters(in: .whitespaces)] }
                for v in ch { r.rust[v, default: Usage()].add(p, a) }
            }
        }
        for f in idx.files["go.mod"] ?? [] {
            guard let t = FS.readText(f, limit: 64 * 1024) else { continue }
            let (p, a) = who(f)
            for v in captures(#"^go\s+(\d+\.\d+(?:\.\d+)?)"#, t) + captures(#"^toolchain\s+go(\S+)"#, t) { r.go[v, default: Usage()].add(p, a) }
        }
        for name in [".nvmrc", ".node-version"] {
            for f in idx.files[name] ?? [] {
                guard let t = FS.readText(f, limit: 1024)?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { continue }
                let (p, a) = who(f)
                r.node[t, default: Usage()].add(p, a)
            }
        }
        for f in idx.files[".python-version"] ?? [] {
            guard let t = FS.readText(f, limit: 1024) else { continue }
            let (p, a) = who(f)
            for line in t.split(separator: "\n") { r.python[line.trimmingCharacters(in: .whitespaces), default: Usage()].add(p, a) }
        }
        for f in idx.files[".ruby-version"] ?? [] {
            guard let t = FS.readText(f, limit: 1024)?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { continue }
            let (p, a) = who(f)
            r.ruby[t.replacingOccurrences(of: "ruby-", with: ""), default: Usage()].add(p, a)
        }
        for f in (idx.files[".tool-versions"] ?? []) + (idx.files["mise.toml"] ?? []) {
            guard let t = FS.readText(f, limit: 8 * 1024) else { continue }
            let (p, a) = who(f)
            for line in t.split(separator: "\n") {
                let parts = line.replacingOccurrences(of: "=", with: " ").replacingOccurrences(of: "\"", with: " ")
                    .split(separator: " ").map(String.init).filter { !$0.isEmpty }
                guard parts.count >= 2 else { continue }
                switch parts[0] {
                case "nodejs", "node": r.node[parts[1], default: Usage()].add(p, a)
                case "python": r.python[parts[1], default: Usage()].add(p, a)
                case "golang", "go": r.go[parts[1], default: Usage()].add(p, a)
                case "java": r.java[parts[1].filter(\.isNumber).prefix(2).description, default: Usage()].add(p, a)
                case "ruby": r.ruby[parts[1], default: Usage()].add(p, a)
                case "rust": r.rust[parts[1], default: Usage()].add(p, a)
                default: break
                }
            }
        }
        for f in idx.files[".fvmrc"] ?? [] {
            guard let t = FS.readText(f, limit: 4096) else { continue }
            let (p, a) = who(f)
            for v in captures(#""flutter(?:SdkVersion)?"\s*:\s*"([^"]+)""#, t) { r.flutter[v, default: Usage()].add(p, a) }
        }
        for f in idx.files["global.json"] ?? [] {
            guard let t = FS.readText(f, limit: 8192) else { continue }
            let (p, a) = who(f)
            for v in captures(#""version"\s*:\s*"([0-9.]+)""#, t) { r.dotnet[v, default: Usage()].add(p, a) }
        }
        for venv in idx.venvs {
            guard let cfg = FS.readText(venv.appendingPathComponent("pyvenv.cfg"), limit: 4096) else { continue }
            let p = idx.projectName(venv.path), a = idx.activity(for: venv)
            for home in captures(#"^home\s*=\s*(.+)$"#, cfg) {
                r.pythonHomes[home.trimmingCharacters(in: .whitespaces), default: Usage()].add(p, a)
            }
            for v in captures(#"^version(?:_info)?\s*=\s*([0-9.]+)"#, cfg) { r.python[v, default: Usage()].add(p, a) }
        }
        return r
    }
}

enum Versions {
    /// "v20.11.0" / "go1.22" / "cpython-3.12.4-macos…" → "20.11.0" / "1.22" / "3.12.4"
    static func normalize(_ s: String) -> String {
        var v = s.lowercased()
        for p in ["cpython-", "python-", "go", "v", "ruby-", "jdk-", "openjdk-"] where v.hasPrefix(p) { v = String(v.dropFirst(p.count)) }
        if let r = v.range(of: #"^\d+(\.\d+)*"#, options: .regularExpression) { return String(v[r]) }
        return v
    }

    /// True when an installed version satisfies a pin: "20" matches "20.11.0", "3.12" matches "3.12.4".
    static func matches(installed: String, pin: String) -> Bool {
        let i = normalize(installed), p = normalize(pin)
        guard !p.isEmpty, !i.isEmpty else { return false }
        return i == p || i.hasPrefix(p + ".")
    }

    static func compare(_ a: String, _ b: String) -> Bool {
        let x = normalize(a).split(separator: ".").map { Int($0) ?? 0 }
        let y = normalize(b).split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l < r }
        }
        return false
    }
}

struct EnvironmentScanner: Scanner {
    let name = "Dev environments"

    struct Install {
        var url: URL
        var version: String
        var extraPaths: [URL] = []
    }

    func scan(_ ctx: ScanContext, _ progress: ScanProgress) -> [CleanupItem] {
        progress.update("Reading project build files…")
        let idx = ctx.projects()
        let req = Requirements.build(idx)
        var items: [CleanupItem] = []
        progress.update("Analyzing Android SDK…")
        items += android(ctx, req)
        progress.update("Analyzing Gradle…")
        items += gradle(ctx, req)
        progress.update("Analyzing language toolchains…")
        items += rust(ctx, req)
        items += go(ctx, req)
        items += node(ctx, req)
        items += python(ctx, req)
        items += java(ctx, req)
        items += misc(ctx, req)
        return items
    }

    // MARK: - Shared verdict logic

    /// Builds one item per installed version, judging it against project pins, the default, and recency.
    func versioned(_ ctx: ScanContext, kind: String, ecosystem: Ecosystem, installs: [Install], pins: [String: Usage],
                   defaults: Set<String> = [], keepNewest: Bool = true, risk: Risk = .low,
                   what: String, impact: String, restore: (String) -> String,
                   command: ((Install) -> ShellCommand?)? = nil, needsAdmin: Bool = false,
                   matcher: ((String, String) -> Bool)? = nil) -> [CleanupItem] {
        guard !installs.isEmpty else { return [] }
        let match = matcher ?? { Versions.matches(installed: $0, pin: $1) }
        let sizes = Sizer.measureMany(installs.map(\.url))
        let newest = installs.map(\.version).max(by: Versions.compare)
        let activeWindow = max(ctx.staleDays * 3, 60)
        let eco = ctx.ecosystemStatus(ecosystem)

        return installs.compactMap { inst in
            let size = sizes[inst.url]?.bytes ?? 0
            guard size >= ctx.minBytes else { return nil }
            var usage = Usage()
            for (pin, u) in pins where match(inst.version, pin) {
                u.projects.forEach { usage.add($0, u.latest) }
            }
            let isDefault = defaults.contains { match(inst.version, $0) || $0 == inst.version }
            let isNewest = inst.version == newest
            let recent = (Age.days(usage.latest) ?? 9999) <= activeWindow

            var rec: Recommendation
            var reason: String
            var whyRemove: String?
            var whyKeep: String?
            if isDefault {
                rec = .keep
                reason = "Your default \(kind)."
                whyKeep = "This is the version your shell uses when nothing else is pinned."
            } else if !usage.projects.isEmpty && recent {
                rec = .keep
                reason = "Used by \(usage.list)."
                whyKeep = "Pinned by \(usage.list), last active \(Fmt.ago(usage.latest))."
            } else if !usage.projects.isEmpty {
                rec = .optional
                reason = "Only pinned by idle projects (\(usage.list))."
                whyRemove = "The projects that pin it were last active \(Fmt.ago(usage.latest))."
                whyKeep = "If you return to \(usage.list), it will need this version again."
            } else if isNewest && keepNewest && !eco.stale {
                rec = .optional
                reason = "Newest installed \(kind). No project pins it."
                whyKeep = "Tools that use \u{201C}latest\u{201D} or no pin may fall back to it."
            } else {
                rec = .recommended
                reason = isNewest ? "No project pins it. " + eco.note : "No project pins it. Newer \(newest.map(Versions.normalize) ?? "") is installed."
                whyRemove = "None of the projects Prune found reference \(kind) \(inst.version)."
                whyKeep = "A project outside your scan locations might still use it."
            }
            let action: CleanupAction = command?(inst).map { .command($0) } ?? .removeFiles
            return CleanupItem(
                category: .environments,
                title: "\(kind) \(inst.version)", subtitle: FS.tildePath(inst.url), group: ecosystem.title,
                paths: [inst.url] + inst.extraPaths, size: size, risk: risk, recommendation: rec, reason: reason,
                whatItIs: what, whyRemove: whyRemove, whyKeep: whyKeep, impact: impact, restore: restore(inst.version),
                lastUsed: sizes[inst.url]?.newest, action: action, needsAdmin: needsAdmin, usedBy: usage.projects.sorted())
        }
    }

    private func dirs(_ url: URL) -> [URL] {
        FS.childDirs(url).filter { !$0.lastPathComponent.hasPrefix(".") && !FS.isSymlink($0) }
    }

    // MARK: - Android

    func androidSDKRoot() -> URL? {
        let env = ProcessInfo.processInfo.environment
        for c in [env["ANDROID_HOME"], env["ANDROID_SDK_ROOT"], FS.home.appendingPathComponent("Library/Android/sdk").path].compactMap({ $0 }) {
            if FS.isDir(URL(fileURLWithPath: c)) { return URL(fileURLWithPath: c) }
        }
        return nil
    }

    func android(_ ctx: ScanContext, _ req: Requirements) -> [CleanupItem] {
        var items: [CleanupItem] = []
        let avdRoot = FS.home.appendingPathComponent(".android/avd")
        // AVD → system image mapping
        var imageUsers: [String: [String]] = [:]
        var avds: [(name: String, dir: URL, ini: URL)] = []
        for d in FS.childDirs(avdRoot) where d.pathExtension == "avd" {
            let name = d.deletingPathExtension().lastPathComponent
            avds.append((name, d, avdRoot.appendingPathComponent(name + ".ini")))
            if let cfg = FS.readText(d.appendingPathComponent("config.ini"), limit: 64 * 1024) {
                for v in Requirements.captures(#"^image\.sysdir\.1\s*=\s*(.+)$"#, cfg) {
                    let key = v.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    imageUsers[key, default: []].append(name)
                }
            }
        }

        if let sdk = androidSDKRoot() {
            let restoreSDK = { (pkg: String) in "sdkmanager \"\(pkg)\" (or Android Studio › Settings › Android SDK)" }

            // NDK: pinned versions; unpinned native builds use the newest.
            let ndks = dirs(sdk.appendingPathComponent("ndk")).map { Install(url: $0, version: $0.lastPathComponent) }
            var ndkPins = req.ndk
            if !req.unpinnedNativeAndroid.projects.isEmpty, let newest = ndks.map(\.version).max(by: Versions.compare) {
                var u = ndkPins[newest] ?? Usage()
                req.unpinnedNativeAndroid.projects.forEach { u.add($0 + " (default NDK)", req.unpinnedNativeAndroid.latest) }
                ndkPins[newest] = u
            }
            items += versioned(ctx, kind: "Android NDK", ecosystem: .android, installs: ndks, pins: ndkPins, keepNewest: true,
                               what: "Android Native Development Kit: compilers and sysroots for C/C++/Rust code in Android apps (React Native, Tauri, Flutter plugins, CMake). Each version is 1–3 GB.",
                               impact: "Native Android builds that need this exact version fail until it's reinstalled. The Android Gradle Plugin can download a pinned NDK automatically if your licenses are accepted.",
                               restore: { restoreSDK("ndk;\($0)") }, matcher: { $0 == $1 || $0.hasPrefix($1) })
            let legacyBundle = sdk.appendingPathComponent("ndk-bundle")
            if FS.isDir(legacyBundle), let i = ctx.cacheItem(.environments, path: legacyBundle.path, title: "Legacy ndk-bundle", subtitle: FS.tildePath(legacyBundle), ecosystem: .android, risk: .low,
                                                             what: "The old single-NDK location, superseded by side-by-side ndk/<version> folders.", impact: "Only very old projects (AGP < 3.5) look here.", restore: restoreSDK("ndk-bundle")) {
                items.append(i)
            }

            let bt = dirs(sdk.appendingPathComponent("build-tools")).map { Install(url: $0, version: $0.lastPathComponent) }
            items += versioned(ctx, kind: "Build-tools", ecosystem: .android, installs: bt, pins: req.buildTools,
                               what: "aapt2, d8, apksigner and zipalign for a specific Android release.",
                               impact: "The Android Gradle Plugin re-downloads the build-tools version it needs on the next build.",
                               restore: { restoreSDK("build-tools;\($0)") })

            let platforms = dirs(sdk.appendingPathComponent("platforms")).map { Install(url: $0, version: $0.lastPathComponent.replacingOccurrences(of: "android-", with: "")) }
            items += versioned(ctx, kind: "Android platform", ecosystem: .android, installs: platforms, pins: req.compileSdk,
                               what: "android.jar and resources for compiling against an API level (compileSdk).",
                               impact: "Projects with this compileSdk need it re-downloaded (~60–150 MB), which Gradle does automatically.",
                               restore: { restoreSDK("platforms;android-\($0)") })

            let sources = dirs(sdk.appendingPathComponent("sources")).map { Install(url: $0, version: $0.lastPathComponent.replacingOccurrences(of: "android-", with: "")) }
            for s in sources {
                if let i = ctx.cacheItem(.environments, path: s.url.path, title: "Android sources \(s.version)", subtitle: FS.tildePath(s.url), ecosystem: .android, risk: .safe,
                                         what: "Android framework source code. It is used only so the IDE can show framework sources while debugging.",
                                         impact: "Android Studio shows decompiled stubs instead of real sources until you reinstall.",
                                         restore: restoreSDK("sources;android-\(s.version)")) { items.append(i) }
            }

            // System images, matched against AVDs.
            for api in FS.childDirs(sdk.appendingPathComponent("system-images")) {
                for tag in FS.childDirs(api) {
                    for abi in FS.childDirs(tag) {
                        let rel = "system-images/\(api.lastPathComponent)/\(tag.lastPathComponent)/\(abi.lastPathComponent)"
                        let users = imageUsers[rel] ?? []
                        let m = Sizer.measure(abi)
                        guard m.bytes >= ctx.minBytes else { continue }
                        let inUse = !users.isEmpty
                        items.append(CleanupItem(
                            category: .environments, title: "Emulator image \(api.lastPathComponent) · \(tag.lastPathComponent)",
                            subtitle: abi.lastPathComponent, group: Ecosystem.android.title, paths: [abi], size: m.bytes, risk: .low,
                            recommendation: inUse ? .keep : .recommended,
                            reason: inUse ? "Used by emulator\(users.count > 1 ? "s" : "") \(users.joined(separator: ", "))." : "No emulator (AVD) uses this image.",
                            whatItIs: "A bootable Android system image for the emulator.",
                            whyRemove: inUse ? nil : "No AVD in ~/.android/avd references it.",
                            whyKeep: inUse ? "Deleting it breaks the emulator\(users.count > 1 ? "s" : "") \(users.joined(separator: ", ")). Delete those first if you don't need them." : nil,
                            impact: "Emulators built on this image won't boot until it's reinstalled (1–4 GB download).",
                            restore: restoreSDK(rel.replacingOccurrences(of: "/", with: ";")), lastUsed: m.newest, usedBy: users))
                    }
                }
            }

            // Obsolete SDK components
            for (rel, what) in [("tools", "The legacy SDK Tools package, replaced by cmdline-tools."),
                                ("extras/android/m2repository", "Legacy offline Maven repo for support libraries. Gradle now fetches these from Google's Maven."),
                                ("extras/google/m2repository", "Legacy offline Maven repo for Google Play services. Gradle now fetches these from Google's Maven."),
                                (".temp", "Leftover SDK Manager download staging."), (".downloadIntermediates", "Leftover SDK Manager download staging.")] {
                let u = sdk.appendingPathComponent(rel)
                guard FS.isDir(u) else { continue }
                if rel == "tools" && !FS.isDir(sdk.appendingPathComponent("cmdline-tools")) { continue }
                if let i = ctx.cacheItem(.environments, path: u.path, title: "Obsolete SDK: \(rel)", subtitle: FS.tildePath(u), ecosystem: .android,
                                         risk: rel.hasPrefix(".") ? .safe : .low, what: what, impact: "Nothing modern depends on it.", restore: nil) {
                    var i = i; i.recommendation = .recommended; i.reason = "Obsolete component."
                    items.append(i)
                }
            }

            let cmakes = dirs(sdk.appendingPathComponent("cmake")).map { Install(url: $0, version: $0.lastPathComponent) }
            if cmakes.count > 1 {
                items += versioned(ctx, kind: "SDK CMake", ecosystem: .android, installs: cmakes, pins: [:],
                                   what: "CMake shipped through the Android SDK for native builds.", impact: "Re-downloaded when a project pins it.",
                                   restore: { restoreSDK("cmake;\($0)") })
            }
        }

        // Emulators (AVDs)
        let running = Shell.run("/bin/ps", ["-Ao", "command"], timeout: 5).stdout
        for avd in avds {
            let m = Sizer.measure(avd.dir)
            guard m.bytes >= ctx.minBytes else { continue }
            let isRunning = running.contains("@\(avd.name)") || running.contains("-avd \(avd.name)")
            let days = Age.days(m.newest) ?? 999
            let stale = days >= ctx.staleDays * 2
            items.append(CleanupItem(
                category: .environments, title: "Emulator \(avd.name)", subtitle: "Android Virtual Device", group: Ecosystem.android.title,
                paths: [avd.dir, avd.ini].filter(FS.exists), size: m.bytes, risk: .review,
                recommendation: isRunning ? .keep : (stale ? .recommended : .optional),
                reason: isRunning ? "Running right now." : (stale ? "Not booted for \(Fmt.age(m.newest))." : "Used \(days == 0 ? "today" : Fmt.age(m.newest) + " ago")."),
                whatItIs: "An Android emulator's disk: user data, installed apps and Quick Boot snapshots.",
                whyRemove: stale ? "You haven't booted it in \(Fmt.age(m.newest))." : nil,
                whyKeep: "Apps, test accounts and settings inside the emulator are lost. You can recreate the device in Device Manager in about a minute.",
                impact: "The emulator disappears from Android Studio's Device Manager. Its system image stays installed.",
                restore: "Android Studio › Device Manager › Create device", lastUsed: m.newest,
                lockedReason: isRunning ? "The emulator is running." : nil))
            let snaps = avd.dir.appendingPathComponent("snapshots")
            if !isRunning, let s = ctx.cacheItem(.environments, path: snaps.path, title: "Quick Boot snapshots · \(avd.name)", subtitle: "Emulator state",
                                                 risk: .safe, what: "Saved RAM/device state so the emulator resumes instantly instead of cold booting.",
                                                 impact: "The next launch is a cold boot (about 30–60 s). Installed apps are kept.", restore: "Automatic on next emulator shutdown",
                                                 group: Ecosystem.android.title) {
                items.append(s)
            }
        }
        return items
    }

    // MARK: - Gradle

    func gradle(_ ctx: ScanContext, _ req: Requirements) -> [CleanupItem] {
        let g = FS.home.appendingPathComponent(".gradle")
        guard FS.isDir(g) else { return [] }
        var items: [CleanupItem] = []
        let dists = dirs(g.appendingPathComponent("wrapper/dists")).compactMap { d -> Install? in
            let n = d.lastPathComponent
            guard n.hasPrefix("gradle-") else { return nil }
            let v = n.dropFirst(7).replacingOccurrences(of: "-bin", with: "").replacingOccurrences(of: "-all", with: "")
            return Install(url: d, version: v)
        }
        items += versioned(ctx, kind: "Gradle", ecosystem: .jvm, installs: dists, pins: req.gradle,
                           what: "A Gradle distribution downloaded by a project's gradlew wrapper.",
                           impact: "The next ./gradlew run for a project that pins this version re-downloads it (~130–200 MB).",
                           restore: { _ in "./gradlew --version (downloads automatically)" }, matcher: { $0 == $1 })

        let caches = g.appendingPathComponent("caches")
        let versionCaches = dirs(caches).filter { $0.lastPathComponent.range(of: #"^\d+\.\d+"#, options: .regularExpression) != nil }
            .map { Install(url: $0, version: $0.lastPathComponent) }
        items += versioned(ctx, kind: "Gradle cache", ecosystem: .jvm, installs: versionCaches, pins: req.gradle, risk: .safe,
                           what: "Version-specific Gradle caches (compiled build scripts, generated Gradle API jars).",
                           impact: "Rebuilt by the matching Gradle version on its next run.",
                           restore: { _ in "Automatic" }, matcher: { $0 == $1 })

        let jdks = dirs(g.appendingPathComponent("jdks")).map { Install(url: $0, version: javaMajor(from: $0) ?? $0.lastPathComponent) }
        items += versioned(ctx, kind: "Gradle-provisioned JDK", ecosystem: .jvm, installs: jdks, pins: req.java,
                           what: "A JDK that Gradle downloaded automatically to satisfy a jvmToolchain() request.",
                           impact: "Gradle downloads it again if a project's toolchain asks for this version.",
                           restore: { _ in "Automatic on next build" }, matcher: { Versions.normalize($0).split(separator: ".").first == Versions.normalize($1).split(separator: ".").first })
        return items
    }

    func javaMajor(from jdk: URL) -> String? {
        for rel in ["release", "Contents/Home/release"] {
            if let t = FS.readText(jdk.appendingPathComponent(rel), limit: 8192),
               let v = Requirements.captures(#"JAVA_VERSION="([^"]+)""#, t).first {
                let parts = v.split(separator: ".")
                if parts.first == "1", parts.count > 1 { return String(parts[1]) }
                return String(parts.first ?? Substring(v))
            }
        }
        return nil
    }

    // MARK: - Rust

    func rust(_ ctx: ScanContext, _ req: Requirements) -> [CleanupItem] {
        let rustup = FS.home.appendingPathComponent(".rustup")
        guard FS.isDir(rustup) else { return [] }
        let settings = FS.readText(rustup.appendingPathComponent("settings.toml"), limit: 32 * 1024) ?? ""
        var defaults = Set(Requirements.captures(#"^default_toolchain\s*=\s*"([^"]+)""#, settings))
        for o in Requirements.captures(#"^"[^"]+"\s*=\s*"([^"]+)""#, settings) { defaults.insert(o) } // directory overrides
        let host = "-" + (Requirements.captures(#"^default_host_triple\s*=\s*"([^"]+)""#, settings).first ?? "aarch64-apple-darwin")
        let strip = { (s: String) in s.replacingOccurrences(of: host, with: "") }
        let installs = dirs(rustup.appendingPathComponent("toolchains")).map { Install(url: $0, version: $0.lastPathComponent) }
        let rustupBin = Shell.which("rustup")
        return versioned(ctx, kind: "Rust toolchain", ecosystem: .rust, installs: installs, pins: req.rust, defaults: defaults,
                         what: "A complete Rust toolchain (rustc, cargo, std library, docs) managed by rustup.",
                         impact: "Projects pinning this toolchain trigger rustup to download it again (~300–600 MB).",
                         restore: { "rustup toolchain install \(strip($0))" },
                         command: { inst in rustupBin.map { ShellCommand(tool: $0, args: ["toolchain", "uninstall", inst.version]) } },
                         matcher: { installed, pin in strip(installed) == strip(pin) || installed == pin })
    }

    // MARK: - Go

    func go(_ ctx: ScanContext, _ req: Requirements) -> [CleanupItem] {
        guard let goBin = Shell.which("go") else { return [] }
        let env = Shell.run(goBin, ["env", "GOMODCACHE", "GOVERSION"], timeout: 15).stdout.split(separator: "\n").map(String.init)
        guard env.count >= 2 else { return [] }
        let modcache = URL(fileURLWithPath: env[0])
        let local = Versions.normalize(env[1])
        // Auto-downloaded toolchains (GOTOOLCHAIN) live in the module cache.
        let tcRoot = modcache.appendingPathComponent("golang.org")
        let installs = FS.childDirs(tcRoot).filter { $0.lastPathComponent.hasPrefix("toolchain@") }.compactMap { d -> Install? in
            guard let v = Requirements.captures(#"-go(\d+\.\d+(?:\.\d+)?)"#, d.lastPathComponent, options: []).first else { return nil }
            return Install(url: d, version: v)
        }
        // A toolchain is only needed if a go.mod requires something newer than the local Go.
        let pins = req.go.filter { Versions.compare(local, $0.key) }
        return versioned(ctx, kind: "Go toolchain", ecosystem: .go, installs: installs, pins: pins, keepNewest: false,
                         what: "A Go toolchain that `go` downloaded automatically because a go.mod asked for a newer version than your installed Go \(local).",
                         impact: "If a project still needs it, `go` downloads it again automatically (~70 MB).",
                         restore: { "Automatic (GOTOOLCHAIN=auto), or go install golang.org/dl/go\($0)@latest" })
    }

    // MARK: - Node

    func node(_ ctx: ScanContext, _ req: Requirements) -> [CleanupItem] {
        let h = FS.home
        var installs: [Install] = []
        var defaults = Set<String>()
        let managers: [(String, String)] = [
            (".nvm/versions/node", "nvm"), (".local/share/fnm/node-versions", "fnm"), ("Library/Application Support/fnm/node-versions", "fnm"),
            (".volta/tools/image/node", "volta"), (".asdf/installs/nodejs", "asdf"), (".local/share/mise/installs/node", "mise"),
            (".n/n/versions/node", "n"),
        ]
        for (rel, _) in managers {
            for d in dirs(h.appendingPathComponent(rel)) { installs.append(Install(url: d, version: d.lastPathComponent)) }
        }
        if FS.isDir(URL(fileURLWithPath: "/usr/local/n/versions/node")) {
            for d in dirs(URL(fileURLWithPath: "/usr/local/n/versions/node")) { installs.append(Install(url: d, version: d.lastPathComponent)) }
        }
        if let a = FS.readText(h.appendingPathComponent(".nvm/alias/default"), limit: 256) { defaults.insert(a.trimmingCharacters(in: .whitespacesAndNewlines)) }
        if let t = FS.readText(h.appendingPathComponent(".volta/tools/user/platform.json"), limit: 4096),
           let v = Requirements.captures(#""runtime"\s*:\s*"([^"]+)""#, t, options: []).first { defaults.insert(v) }
        let fnmDefault = h.appendingPathComponent(".local/share/fnm/aliases/default")
        if let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: fnmDefault.path),
           let v = dest.split(separator: "/").first(where: { $0.hasPrefix("v") }) { defaults.insert(String(v)) }
        // lts/* style pins can't be resolved offline — keep the newest even-numbered (LTS) version.
        var pins = req.node.filter { !$0.key.hasPrefix("lts") && $0.key != "node" && $0.key != "stable" }
        if req.node.keys.contains(where: { $0.hasPrefix("lts") }),
           let lts = installs.map(\.version).filter({ (Int(Versions.normalize($0).split(separator: ".").first ?? "") ?? 1) % 2 == 0 }).max(by: Versions.compare) {
            pins[lts] = req.node.first { $0.key.hasPrefix("lts") }?.value
        }
        var items = versioned(ctx, kind: "Node.js", ecosystem: .node, installs: installs, pins: pins, defaults: defaults,
                              what: "A Node.js runtime installed by a version manager (nvm, fnm, volta, asdf, mise or n), including its globally installed npm packages.",
                              impact: "Projects pinned to this version (.nvmrc) need it reinstalled, along with any global packages installed under it.",
                              restore: { "nvm install \(Versions.normalize($0))  (or your version manager's equivalent)" })

        // node-gyp headers for Node versions no longer installed.
        let systemNodes = Shell.whichAll("node").map { Versions.normalize(Shell.run($0, ["-v"], timeout: 5).stdout) }
        let installed = Set(installs.map { Versions.normalize($0.version) } + systemNodes)
        for d in dirs(h.appendingPathComponent("Library/Caches/node-gyp")) where !installed.contains(Versions.normalize(d.lastPathComponent)) {
            if let i = ctx.cacheItem(.environments, path: d.path, title: "node-gyp headers \(d.lastPathComponent)", subtitle: FS.tildePath(d), ecosystem: .node, risk: .safe,
                                     what: "C++ headers that node-gyp downloaded to compile native addons for Node \(d.lastPathComponent).",
                                     impact: "Re-downloaded if you build native modules for that Node version again.",
                                     restore: "Automatic") {
                var i = i; i.reason = "Node \(d.lastPathComponent) is no longer installed."; i.recommendation = .recommended
                items.append(i)
            }
        }
        return items
    }

    // MARK: - Python

    func python(_ ctx: ScanContext, _ req: Requirements) -> [CleanupItem] {
        let h = FS.home
        var items: [CleanupItem] = []
        let pins = req.python
        // A virtualenv's home path pins the exact interpreter install.
        func pinsWithHomes(_ base: URL) -> [String: Usage] {
            var p = pins
            for (home, u) in req.pythonHomes where home.hasPrefix(base.path) {
                let comp = home.dropFirst(base.path.count + 1).split(separator: "/").first.map(String.init) ?? ""
                var x = p[comp] ?? Usage(); u.projects.forEach { x.add($0 + " (virtualenv)", u.latest) }; p[comp] = x
            }
            return p
        }
        let uvRoot = h.appendingPathComponent(".local/share/uv/python")
        let uvInstalls = dirs(uvRoot).compactMap { d -> Install? in
            let n = d.lastPathComponent
            guard Requirements.captures(#"-(\d+\.\d+\.\d+)"#, n, options: []).first != nil else { return nil }  // skip minor-version aliases
            return Install(url: d, version: n)
        }
        let uvBin = Shell.which("uv")
        var uvDefaults = Set<String>()
        if let g = FS.readText(h.appendingPathComponent(".config/uv/.python-version"), limit: 256) { uvDefaults.insert(g.trimmingCharacters(in: .whitespacesAndNewlines)) }
        items += versioned(ctx, kind: "Python (uv)", ecosystem: .python, installs: uvInstalls, pins: pinsWithHomes(uvRoot), defaults: uvDefaults,
                           what: "A standalone CPython build managed by uv.",
                           impact: "Virtualenvs created from this interpreter stop working until it's reinstalled. uv reinstalls on demand in seconds.",
                           restore: { "uv python install \(Versions.normalize($0))" },
                           command: { inst in uvBin.map { ShellCommand(tool: $0, args: ["python", "uninstall", Versions.normalize(inst.version)]) } },
                           matcher: { installed, pin in installed == pin || Versions.matches(installed: installed, pin: pin) })

        let pyenvRoot = h.appendingPathComponent(".pyenv/versions")
        let pyenvInstalls = dirs(pyenvRoot).map { Install(url: $0, version: $0.lastPathComponent) }
        var pyenvDefaults = Set<String>()
        if let g = FS.readText(h.appendingPathComponent(".pyenv/version"), limit: 1024) {
            g.split(separator: "\n").forEach { pyenvDefaults.insert($0.trimmingCharacters(in: .whitespaces)) }
        }
        items += versioned(ctx, kind: "Python (pyenv)", ecosystem: .python, installs: pyenvInstalls, pins: pinsWithHomes(pyenvRoot), defaults: pyenvDefaults,
                           what: "A Python interpreter compiled by pyenv.", impact: "Reinstalling means compiling Python from source again (a few minutes).",
                           restore: { "pyenv install \($0)" },
                           command: { inst in Shell.which("pyenv").map { ShellCommand(tool: $0, args: ["uninstall", "-f", inst.version]) } },
                           matcher: { installed, pin in installed == pin || Versions.matches(installed: installed, pin: pin) })

        // python.org framework installs
        let fw = URL(fileURLWithPath: "/Library/Frameworks/Python.framework/Versions")
        let current = (try? FileManager.default.destinationOfSymbolicLink(atPath: fw.appendingPathComponent("Current").path)) ?? ""
        let fwInstalls = dirs(fw).filter { $0.lastPathComponent != "Current" }.map { Install(url: $0, version: $0.lastPathComponent) }
        items += versioned(ctx, kind: "Python.org", ecosystem: .python, installs: fwInstalls, pins: pinsWithHomes(fw), defaults: [current],
                           risk: .review, what: "A Python installed from python.org (system-wide framework).",
                           impact: "Scripts, venvs and tools using this interpreter break. Reinstall from python.org.",
                           restore: { "Download Python \($0) from python.org" }, needsAdmin: true)

        // conda environments
        for base in ["miniconda3", "anaconda3", "miniforge3", "mambaforge", "opt/miniconda3"].map({ h.appendingPathComponent($0) }) {
            for env in dirs(base.appendingPathComponent("envs")) {
                let history = env.appendingPathComponent("conda-meta/history")
                let used = FS.mtime(history)
                guard let i = ctx.cacheItem(.environments, path: env.path, title: "Conda env \(env.lastPathComponent)", subtitle: FS.tildePath(env), ecosystem: .python, risk: .review,
                                            what: "A conda environment with its own Python and packages.",
                                            impact: "Anything that activates this environment stops working until it is recreated.",
                                            restore: "conda env create -f environment.yml") else { continue }
                var x = i
                x.lastUsed = used
                let stale = (Age.days(used) ?? 999) >= ctx.staleDays * 2
                x.recommendation = stale ? .recommended : .optional
                x.reason = stale ? "Packages unchanged for \(Fmt.age(used))." : "Modified \(Fmt.ago(used))."
                items.append(x)
            }
        }
        return items
    }

    // MARK: - Java

    func java(_ ctx: ScanContext, _ req: Requirements) -> [CleanupItem] {
        var items: [CleanupItem] = []
        let defaultHome = Shell.run("/usr/libexec/java_home", [], timeout: 5).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let majorMatch: (String, String) -> Bool = { Versions.normalize($0).split(separator: ".").first == Versions.normalize($1).split(separator: ".").first }
        for (root, admin) in [(URL(fileURLWithPath: "/Library/Java/JavaVirtualMachines"), true),
                              (FS.home.appendingPathComponent("Library/Java/JavaVirtualMachines"), false),
                              (FS.home.appendingPathComponent(".sdkman/candidates/java"), false)] {
            let installs = dirs(root).map { d in Install(url: d, version: javaMajor(from: d) ?? d.lastPathComponent) }
            var defaults = Set<String>()
            for i in installs where !defaultHome.isEmpty && defaultHome.hasPrefix(i.url.path) { defaults.insert(i.version) }
            var named = versioned(ctx, kind: "JDK", ecosystem: .jvm, installs: installs, pins: req.java, defaults: defaults,
                                  risk: admin ? .review : .low,
                                  what: "A Java Development Kit. Gradle, Maven, Android tooling and IDEs may use it.",
                                  impact: "Builds that need this Java major version fail until another JDK of that version is installed.",
                                  restore: { "brew install --cask zulu@\($0)  (or download from adoptium.net)" },
                                  needsAdmin: admin, matcher: majorMatch)
            for i in named.indices { named[i].title = "JDK \(named[i].title.replacingOccurrences(of: "JDK ", with: "")) · \(named[i].paths[0].lastPathComponent)" }
            items += named
        }
        return items
    }

    // MARK: - Ruby, Flutter, .NET, ESP-IDF

    func misc(_ ctx: ScanContext, _ req: Requirements) -> [CleanupItem] {
        let h = FS.home
        var items: [CleanupItem] = []
        var rubies: [Install] = []
        for rel in [".rbenv/versions", ".rvm/rubies", ".asdf/installs/ruby", ".local/share/mise/installs/ruby"] {
            rubies += dirs(h.appendingPathComponent(rel)).map { Install(url: $0, version: $0.lastPathComponent.replacingOccurrences(of: "ruby-", with: "")) }
        }
        var rubyDefault = Set<String>()
        if let g = FS.readText(h.appendingPathComponent(".rbenv/version"), limit: 256) { rubyDefault.insert(g.trimmingCharacters(in: .whitespacesAndNewlines)) }
        items += versioned(ctx, kind: "Ruby", ecosystem: .ruby, installs: rubies, pins: req.ruby, defaults: rubyDefault,
                           what: "A Ruby interpreter with its installed gems (CocoaPods and fastlane often live here).",
                           impact: "Gems installed under this Ruby (pod, fastlane, bundler) disappear with it.",
                           restore: { "rbenv install \($0)" })

        var flutters: [Install] = []
        for rel in ["fvm/versions", "Library/Application Support/fvm/versions"] {
            flutters += dirs(h.appendingPathComponent(rel)).map { Install(url: $0, version: $0.lastPathComponent) }
        }
        items += versioned(ctx, kind: "Flutter SDK", ecosystem: .flutter, installs: flutters, pins: req.flutter,
                           what: "A Flutter SDK version managed by FVM.", impact: "Projects pinned to it (.fvmrc) need `fvm install` again.",
                           restore: { "fvm install \($0)" }, matcher: { $0 == $1 })

        let dotnet = dirs(h.appendingPathComponent(".dotnet/sdk")).map { Install(url: $0, version: $0.lastPathComponent) }
            + dirs(URL(fileURLWithPath: "/usr/local/share/dotnet/sdk")).map { Install(url: $0, version: $0.lastPathComponent) }
        items += versioned(ctx, kind: ".NET SDK", ecosystem: .dotnet, installs: dotnet, pins: req.dotnet,
                           what: "A .NET SDK version.", impact: "Projects whose global.json pins it fail to build.",
                           restore: { "dotnet-install.sh --version \($0)" },
                           needsAdmin: false)

        // ESP-IDF: several versions of each cross-compiler accumulate across IDF upgrades.
        let espTools = h.appendingPathComponent(".espressif/tools")
        for tool in dirs(espTools) {
            let versions = dirs(tool).map { Install(url: $0, version: $0.lastPathComponent) }
            guard versions.count > 1 else { continue }
            items += versioned(ctx, kind: "ESP-IDF \(tool.lastPathComponent)", ecosystem: .esp, installs: versions, pins: [:],
                               what: "A cross-compiler/tool version installed by ESP-IDF. Each IDF release pins its own tool versions.",
                               impact: "An older IDF version that pinned it needs `install.sh` again.",
                               restore: { _ in "./install.sh in the matching ESP-IDF checkout (or EIM)" })
        }
        let espPy = h.appendingPathComponent(".espressif/python_env")
        let pyEnvs = dirs(espPy).map { Install(url: $0, version: $0.lastPathComponent) }
        if pyEnvs.count > 1 {
            items += versioned(ctx, kind: "ESP-IDF Python env", ecosystem: .esp, installs: pyEnvs, pins: [:],
                               what: "A Python virtualenv for one ESP-IDF version.", impact: "Re-created by install.sh for that IDF version.",
                               restore: { _ in "./install.sh" })
        }
        return items
    }
}
