import Foundation

/// A folder that looks like build output or a dependency cache inside a project.
struct ArtifactRule {
    let id: String
    let names: Set<String>
    var prefix: String? = nil
    let kind: String
    let ecosystem: Ecosystem
    let risk: Risk
    var aggregate = false
    let validate: (_ dir: URL, _ siblings: Set<String>) -> Bool
    let what: String
    let impact: String
    let restore: (_ siblings: Set<String>) -> String?
}

struct ArtifactCandidate {
    var url: URL
    var rule: ArtifactRule
    var siblings: Set<String>
}

struct ProjectInfo {
    var root: URL
    var markers: Set<String>
    var ecosystems: Set<Ecosystem>
    var gitKind: GitKind
    var signal: Date?          // own activity signal
    enum GitKind { case none, repo, linked }
}

final class ProjectIndex {
    var projects: [String: ProjectInfo] = [:]
    var artifacts: [ArtifactCandidate] = []
    var gitRepos: [URL] = []
    var gitFileDirs: [URL] = []
    var files: [String: [URL]] = [:]
    /// Large files found directly on selected external disks, independent of Spotlight.
    var largeFiles: [URL] = []
    var venvs: [URL] = []
    var ecosystemActivity: [Ecosystem: Date] = [:]
    var ecosystemLatestProject: [Ecosystem: String] = [:]
    var ecosystemProjects: [Ecosystem: Set<String>] = [:]
    var scopeActivity: [String: Date] = [:]
    var dirsVisited = 0
    var unreadableDirs = 0
    var depthLimited = false
    var directoryLimitReached = false
    var roots: [URL] = []

    var coverageWarning: String? {
        var reasons: [String] = []
        if directoryLimitReached { reasons.append("the 1,500,000-directory limit was reached") }
        if depthLimited { reasons.append("some folders exceeded the 14-level project-walk limit") }
        if unreadableDirs > 0 { reasons.append("\(unreadableDirs) folders could not be read") }
        return reasons.isEmpty ? nil : "Project discovery was incomplete: " + reasons.joined(separator: "; ") + "."
    }

    // MARK: - Lookup helpers

    /// Nearest ancestor (or self) that is a git checkout; falls back to the outermost project.
    func scopeRoot(for url: URL) -> String? {
        var p = url.path
        var outermost: String?
        while p.count > 1 {
            if let proj = projects[p] {
                if proj.gitKind != .none { return p }
                outermost = p
            }
            p = (p as NSString).deletingLastPathComponent
        }
        return outermost
    }

    func outermostProject(for url: URL) -> String? {
        var p = url.path
        var found: String?
        while p.count > 1 {
            if projects[p] != nil { found = p }
            p = (p as NSString).deletingLastPathComponent
        }
        return found
    }

    func activity(for url: URL) -> Date? {
        scopeRoot(for: url).flatMap { scopeActivity[$0] }
    }

    func displayName(for path: String) -> String {
        let url = URL(fileURLWithPath: path)
        if let top = outermostProject(for: url) {
            let topName = (top as NSString).lastPathComponent
            if top == path { return topName }
            return topName + "/" + path.dropFirst(top.count + 1)
        }
        return url.deletingLastPathComponent().lastPathComponent + "/" + url.lastPathComponent
    }

    func projectName(_ path: String) -> String {
        if let top = outermostProject(for: URL(fileURLWithPath: path)) { return (top as NSString).lastPathComponent }
        return ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
    }

    // MARK: - Build

    static let markerFiles: [String: Ecosystem] = [
        "package.json": .node, "deno.json": .deno, "deno.jsonc": .deno, "Cargo.toml": .rust, "go.mod": .go,
        "pyproject.toml": .python, "requirements.txt": .python, "setup.py": .python, "Pipfile": .python, "uv.lock": .python,
        "build.gradle": .jvm, "build.gradle.kts": .jvm, "settings.gradle": .jvm, "settings.gradle.kts": .jvm,
        "pom.xml": .jvm, "build.sbt": .jvm, "Package.swift": .apple, "Podfile": .apple, "pubspec.yaml": .flutter,
        "Gemfile": .ruby, "composer.json": .php, "mix.exs": .elixir, "stack.yaml": .haskell, "CMakeLists.txt": .cpp,
        "sdkconfig": .esp, "idf_component.yml": .esp, "build.zig": .zig, "global.json": .dotnet, "main.tf": .terraform,
    ]

    static let interestingFiles: Set<String> = [
        "build.gradle", "build.gradle.kts", "gradle-wrapper.properties", "gradle.properties", "rust-toolchain",
        "rust-toolchain.toml", "go.mod", ".nvmrc", ".node-version", ".python-version", ".tool-versions",
        "pubspec.yaml", "sdkconfig", "mise.toml", ".sdkmanrc", "libs.versions.toml", ".ruby-version", ".fvmrc", "global.json",
    ]

    /// Folders never descended into while looking for projects.
    static let skipNames: Set<String> = [
        ".git", ".hg", ".svn", ".idea", ".vscode", ".github", ".yarn", ".Trash", ".Trashes", ".Spotlight-V100",
        ".fseventsd", ".DocumentRevisions-V100", "site-packages", "vendor", "Carthage", ".npm", ".gradle-cache",
    ]
    static let skipHomeTop: Set<String> = ["Library", "Applications", "Movies", "Music", "Pictures", "Public"]

    /// Per-thread findings, merged once the walk completes.
    private struct Local {
        var projects: [String: ProjectInfo] = [:]
        var artifacts: [ArtifactCandidate] = []
        var gitRepos: [URL] = []
        var gitFileDirs: [URL] = []
        var files: [String: [URL]] = [:]
        var largeFiles: [URL] = []
        var venvs: [URL] = []
        var visited = 0
        var unreadable = 0
        var depthLimited = false
    }

    static func build(roots: [URL], settings: SettingsSnapshot, largeFileRoots: [URL] = [], progress: @escaping (String) -> Void) -> ProjectIndex {
        let idx = ProjectIndex()
        idx.roots = roots
        let home = FS.home.path
        let skipPaths: Set<String> = [
            home + "/go/pkg", home + "/Library", "/System", "/Library", "/private", "/usr", "/bin", "/sbin", "/dev",
            "/Volumes", "/cores", "/opt", "/Applications",
        ]
        let rulesByName = ArtifactRules.byName
        let maxDepth = 14
        let maxDirs = 1_500_000
        let explicitRoots = Set(roots.map { $0.standardizedFileURL.path })
        let excluded = (settings.excludedPaths + settings.excludedVolumes).map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        let largeThreshold = Int64(max(1, settings.largeFileMB)) * 1_048_576
        let largeRootPaths = largeFileRoots.map { $0.standardizedFileURL.path }

        // Work-stealing walk across threads.
        let cond = NSCondition()
        var stack: [(String, Int)] = roots.map { ($0.path, 0) }
        var pending = stack.count
        var visitedPaths = Set<String>()
        var totalVisited = 0
        var lastReport = Date()
        var locals: [Local] = []

        func process(_ dir: String, _ depth: Int, _ local: inout Local, _ push: inout [(String, Int)]) {
            guard !settings.isExcluded(URL(fileURLWithPath: dir)) else { return }
            local.visited += 1
            let dirURL = URL(fileURLWithPath: dir)
            guard let listed = FS.list(dir) else { local.unreadable += 1; return }
            let entries = excluded.isEmpty ? listed : listed.filter { entry in
                let child = (dir as NSString).appendingPathComponent(entry.name)
                return !excluded.contains { child == $0 || FS.isAncestor($0, of: child) }
            }
            let names = Set(entries.map(\.name))

            // A folder tagged as a cache by the CACHEDIR.TAG standard.
            if depth > 0, names.contains("CACHEDIR.TAG") {
                local.artifacts.append(ArtifactCandidate(url: dirURL, rule: ArtifactRules.cachedirTag, siblings: []))
                return
            }
            var markers = Set<String>()
            var ecos = Set<Ecosystem>()
            for n in names {
                if let e = markerFiles[n] { markers.insert(n); ecos.insert(e) }
                else if n.hasSuffix(".xcodeproj") || n.hasSuffix(".xcworkspace") { markers.insert(n); ecos.insert(.apple) }
                else if n.hasSuffix(".csproj") { markers.insert(n); ecos.insert(.dotnet) }
            }
            var gitKind = ProjectInfo.GitKind.none
            if let g = entries.first(where: { $0.name == ".git" }) {
                gitKind = g.isDir ? .repo : .linked
                if g.isDir { local.gitRepos.append(dirURL) } else { local.gitFileDirs.append(dirURL) }
            }
            if !markers.isEmpty || gitKind != .none {
                local.projects[dir] = ProjectInfo(root: dirURL, markers: markers, ecosystems: ecos, gitKind: gitKind, signal: nil)
            }
            for e in entries where !e.isDir && interestingFiles.contains(e.name) {
                local.files[e.name, default: []].append(dirURL.appendingPathComponent(e.name))
            }
            if largeRootPaths.contains(where: { dir == $0 || FS.isAncestor($0, of: dir) }) {
                for e in entries where !e.isDir && !e.isLink {
                    let child = dirURL.appendingPathComponent(e.name)
                    guard !settings.isExcluded(child) else { continue }
                    var st = stat()
                    if lstat(child.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG,
                       Int64(st.st_blocks) * 512 >= largeThreshold {
                        local.largeFiles.append(child)
                    }
                }
            }
            for e in entries where e.isDir && !e.isLink {
                let name = e.name
                let child = dir == "/" ? "/" + name : dir + "/" + name
                // A separately selected root has its own depth budget, even if its parent is also scanned.
                if explicitRoots.contains(child) { continue }
                if skipPaths.contains(child) { continue }
                if name.hasSuffix(".app") || name.hasSuffix(".photoslibrary") || name.hasSuffix(".xcodeproj")
                    || name.hasSuffix(".xcworkspace") || name.hasSuffix(".bundle") || name.hasSuffix(".framework") { continue }
                if dir == home && (name.hasPrefix(".") || skipHomeTop.contains(name)) { continue }
                if settings.isExcluded(URL(fileURLWithPath: child)) { continue }

                // <prefix>/lib/node_modules is a Node installation's global packages (npm itself lives there).
                if name == "node_modules" && (dir as NSString).lastPathComponent == "lib" { continue }
                if let rule = rulesByName[name] ?? ArtifactRules.prefixRules.first(where: { name.hasPrefix($0.prefix!) }) {
                    let childURL = URL(fileURLWithPath: child)
                    if rule.validate(childURL, names) {
                        local.artifacts.append(ArtifactCandidate(url: childURL, rule: rule, siblings: names))
                        if rule.id == "venv" { local.venvs.append(childURL) }
                        continue
                    }
                    if rule.id == "node_modules" { continue }
                }
                if skipNames.contains(name) { continue }
                if depth + 1 <= maxDepth { push.append((child, depth + 1)) }
                else { local.depthLimited = true }
            }
        }

        let threads = min(12, max(4, ProcessInfo.processInfo.activeProcessorCount))
        let group = DispatchGroup()
        for _ in 0..<threads {
            group.enter()
            let t = Thread {
                var local = Local()
                var push: [(String, Int)] = []
                while true {
                    cond.lock()
                    while stack.isEmpty && pending > 0 { cond.wait() }
                    guard let (dir, depth) = stack.popLast() else { cond.unlock(); break }
                    guard visitedPaths.insert(dir).inserted else {
                        pending -= 1
                        cond.broadcast()
                        cond.unlock()
                        continue
                    }
                    totalVisited += 1
                    let report = Date().timeIntervalSince(lastReport) > 0.25
                    if report { lastReport = Date() }
                    let overBudget = totalVisited > maxDirs
                    cond.unlock()
                    if report { progress(FS.tildePath(URL(fileURLWithPath: dir))) }

                    push.removeAll(keepingCapacity: true)
                    if !overBudget { process(dir, depth, &local, &push) }

                    cond.lock()
                    stack.append(contentsOf: push)
                    pending += push.count - 1
                    cond.broadcast()
                    cond.unlock()
                }
                cond.lock(); locals.append(local); cond.unlock()
                group.leave()
            }
            t.stackSize = 1 << 20
            t.start()
        }
        group.wait()

        for l in locals {
            idx.projects.merge(l.projects) { a, _ in a }
            idx.artifacts += l.artifacts
            idx.gitRepos += l.gitRepos
            idx.gitFileDirs += l.gitFileDirs
            idx.venvs += l.venvs
            idx.largeFiles += l.largeFiles
            for (k, v) in l.files { idx.files[k, default: []] += v }
            idx.dirsVisited += l.visited
            idx.unreadableDirs += l.unreadable
            idx.depthLimited = idx.depthLimited || l.depthLimited
        }
        idx.directoryLimitReached = totalVisited > maxDirs
        idx.artifacts.sort { $0.url.path < $1.url.path }
        idx.computeActivity()
        return idx
    }

    private func computeActivity() {
        let artifactNames = ArtifactRules.allNames
        for (path, var p) in projects {
            var signals: [Date] = []
            if let m = FS.newestChildMtime(p.root, skipping: artifactNames.union([".git"])) { signals.append(m) }
            var gitDir: URL?
            switch p.gitKind {
            case .repo: gitDir = p.root.appendingPathComponent(".git")
            case .linked: gitDir = Git.resolveGitDir(worktree: p.root)
            case .none: break
            }
            if let g = gitDir {
                for f in ["index", "HEAD", "logs/HEAD", "FETCH_HEAD", "ORIG_HEAD"] {
                    if let m = FS.mtime(g.appendingPathComponent(f)) { signals.append(m) }
                }
            }
            p.signal = signals.max()
            projects[path] = p
        }
        // Roll signals up into their scope (git checkout or outermost project).
        for (path, p) in projects {
            guard let s = p.signal, let scope = scopeRoot(for: p.root) else { continue }
            if s > (scopeActivity[scope] ?? .distantPast) { scopeActivity[scope] = s }
            _ = path
        }
        let vendored = ["/third_party/", "/third-party/", "/external/", "/vendor/", "/deps/", "/.tmp/", "/tmp/"]
        for (_, p) in projects {
            // Vendored checkouts (third_party/llama.cpp…) say nothing about which ecosystems *you* use.
            if vendored.contains(where: { p.root.path.contains($0) }) { continue }
            let act = scopeRoot(for: p.root).flatMap { scopeActivity[$0] } ?? p.signal
            var ecos = p.ecosystems
            if ecos.contains(.jvm), isAndroidProject(p.root) { ecos.insert(.android) }
            for e in ecos {
                ecosystemProjects[e, default: []].insert(projectName(p.root.path))
                if let a = act, a > (ecosystemActivity[e] ?? .distantPast) {
                    ecosystemActivity[e] = a
                    ecosystemLatestProject[e] = projectName(p.root.path)
                }
            }
        }
    }

    private func isAndroidProject(_ root: URL) -> Bool {
        for f in ["build.gradle", "build.gradle.kts", "app/build.gradle", "app/build.gradle.kts"] {
            if let t = FS.readText(root.appendingPathComponent(f), limit: 64 * 1024),
               t.contains("com.android") || t.contains("android {") || t.contains("androidApplication") { return true }
        }
        return false
    }

    /// Bump scope activity with artifact timestamps (a dev server touching .next means the project is alive).
    func noteArtifactActivity(_ url: URL, _ date: Date?) {
        guard let date, let scope = scopeRoot(for: url) else { return }
        if date > (scopeActivity[scope] ?? .distantPast) { scopeActivity[scope] = date }
    }
}

enum ArtifactRules {
    static func has(_ s: Set<String>, _ names: String...) -> Bool { names.contains { s.contains($0) } }
    static func inside(_ dir: URL, _ names: String...) -> Bool { names.contains { FS.exists(dir.appendingPathComponent($0)) } }

    static func nodeRestore(_ s: Set<String>) -> String? {
        if has(s, "pnpm-lock.yaml") { return "pnpm install" }
        if has(s, "yarn.lock") { return "yarn install" }
        if has(s, "bun.lockb", "bun.lock") { return "bun install" }
        if has(s, "package-lock.json") { return "npm ci" }
        return has(s, "package.json") ? "npm install" : nil
    }

    static func pyRestore(_ s: Set<String>) -> String? {
        if has(s, "uv.lock") { return "uv sync" }
        if has(s, "poetry.lock") { return "poetry install" }
        if has(s, "Pipfile") { return "pipenv install" }
        if has(s, "requirements.txt") { return "python3 -m venv .venv && .venv/bin/pip install -r requirements.txt" }
        if has(s, "pyproject.toml") { return "python3 -m venv .venv && .venv/bin/pip install -e ." }
        return "Recreate the virtualenv and reinstall packages"
    }

    static let cachedirTag = ArtifactRule(
        id: "cachedir", names: [], kind: "Tagged cache", ecosystem: .cpp, risk: .safe,
        validate: { _, _ in true },
        what: "A folder marked with CACHEDIR.TAG, the cross-tool convention for \u{201C}this is a disposable cache\u{201D} (used by Cargo, Gradle, and others).",
        impact: "The tool that owns it recreates it on its next run.",
        restore: { _ in "Recreated automatically by the owning tool" })

    static let rules: [ArtifactRule] = [
        ArtifactRule(id: "node_modules", names: ["node_modules"], kind: "node_modules", ecosystem: .node, risk: .low,
                     validate: { _, _ in true },
                     what: "Installed npm/yarn/pnpm/bun packages for this project. Every file can be reinstalled from package.json and the lockfile.",
                     impact: "The project won't run or build until you reinstall dependencies. A fresh install takes from a few seconds to a few minutes, and is faster when the package-manager cache is warm.",
                     restore: nodeRestore),
        ArtifactRule(id: "next", names: [".next"], kind: "Next.js build", ecosystem: .node, risk: .safe,
                     validate: { _, s in has(s, "package.json") },
                     what: "Next.js build output and incremental compile cache.",
                     impact: "The next `next dev` or `next build` is slower the first time.",
                     restore: { _ in "next build (or just run next dev)" }),
        ArtifactRule(id: "fwcache", names: [".nuxt", ".svelte-kit", ".turbo", ".parcel-cache", ".astro", ".docusaurus", ".vite", ".open-next", ".serverless", ".angular", ".expo-shared"],
                     kind: "Framework cache", ecosystem: .node, risk: .safe,
                     validate: { _, s in has(s, "package.json") },
                     what: "Build/compile cache generated by the project's framework or bundler (Nuxt, SvelteKit, Turborepo, Parcel, Astro, Vite, Angular…).",
                     impact: "The first build or dev start is slower while the cache is rebuilt.",
                     restore: { _ in "Rebuilt on next build or dev run" }),
        ArtifactRule(id: "nuxtout", names: [".output"], kind: "Nuxt output", ecosystem: .node, risk: .safe,
                     validate: { _, s in s.contains { $0.hasPrefix("nuxt.config") } },
                     what: "Nuxt/Nitro production build output.", impact: "Rebuild before deploying.",
                     restore: { _ in "nuxt build" }),
        ArtifactRule(id: "jscache", names: [".cache"], kind: "Bundler cache", ecosystem: .node, risk: .low,
                     validate: { _, s in has(s, "package.json") },
                     what: "Project-local cache used by Gatsby, Parcel, Babel, ESLint and similar tools.",
                     impact: "Tools rebuild their caches on the next run.", restore: { _ in "Rebuilt automatically" }),
        ArtifactRule(id: "coverage", names: ["coverage", ".nyc_output", "htmlcov"], kind: "Test coverage", ecosystem: .node, risk: .safe,
                     validate: { d, _ in inside(d, "lcov.info", "coverage-final.json", "lcov-report", "index.html", "coverage.json") || d.lastPathComponent == ".nyc_output" },
                     what: "Coverage reports generated by your test runner.", impact: "None, they are regenerated by the next coverage run.",
                     restore: { _ in "Run tests with coverage again" }),
        ArtifactRule(id: "storybook", names: ["storybook-static"], kind: "Storybook build", ecosystem: .node, risk: .safe,
                     validate: { _, s in has(s, "package.json") },
                     what: "Static Storybook export.", impact: "Rebuild if you need to publish it.", restore: { _ in "build-storybook" }),
        ArtifactRule(id: "dist", names: ["dist"], kind: "Build output", ecosystem: .node, risk: .low,
                     validate: { d, s in has(s, "package.json", "pyproject.toml", "setup.py", "Cargo.toml", "tsconfig.json") && !inside(d, ".git") },
                     what: "Compiled/bundled output of the project's build step.",
                     impact: "Anything that serves or publishes this folder needs a rebuild first.",
                     restore: { s in has(s, "package.json") ? "npm run build" : "Re-run the project's build" }),
        ArtifactRule(id: "build", names: ["build"], kind: "Build output", ecosystem: .jvm, risk: .low,
                     validate: { d, s in
                         if inside(d, ".git") { return false }
                         if has(s, "build.gradle", "build.gradle.kts", "package.json", "pubspec.yaml", "setup.py", "pyproject.toml") { return true }
                         return inside(d, "CMakeCache.txt", "build.ninja", "CMakeFiles")
                     },
                     what: "Build output from Gradle, CMake, Flutter, Python or a JS bundler. Validated against a build file in the parent folder.",
                     impact: "The next build is a full rebuild instead of an incremental one.",
                     restore: { s in
                         if has(s, "build.gradle", "build.gradle.kts") { return "./gradlew assemble" }
                         if has(s, "pubspec.yaml") { return "flutter build" }
                         if has(s, "package.json") { return "npm run build" }
                         return "cmake --build (re-configure first)"
                     }),
        ArtifactRule(id: "out", names: ["out"], kind: "Static export", ecosystem: .node, risk: .low,
                     validate: { _, s in has(s, "package.json") && s.contains { $0.hasPrefix("next.config") } },
                     what: "Next.js static export output.", impact: "Re-export before deploying.", restore: { _ in "next build" }),
        ArtifactRule(id: "target", names: ["target"], kind: "Rust/Maven target", ecosystem: .rust, risk: .low,
                     validate: { d, s in has(s, "Cargo.toml", "pom.xml", "build.sbt") || inside(d, "CACHEDIR.TAG", ".rustc_info.json") },
                     what: "Compiler output: Rust's target/ (incremental builds, dependencies, binaries) or Maven/sbt target/. Rust target folders often grow to many gigabytes.",
                     impact: "The next build recompiles everything from scratch, which can take minutes for large Rust projects.",
                     restore: { s in has(s, "pom.xml") ? "mvn package" : "cargo build" }),
        ArtifactRule(id: "gradle", names: [".gradle"], kind: "Gradle project cache", ecosystem: .jvm, risk: .safe,
                     validate: { _, s in has(s, "settings.gradle", "settings.gradle.kts", "build.gradle", "build.gradle.kts", "gradlew") },
                     what: "Per-project Gradle state (file hashes, configuration cache).", impact: "Next Gradle build re-hashes inputs; slightly slower.",
                     restore: { _ in "Recreated by the next Gradle build" }),
        ArtifactRule(id: "cxx", names: [".cxx", ".externalNativeBuild"], kind: "Android native build", ecosystem: .android, risk: .safe,
                     validate: { _, s in has(s, "build.gradle", "build.gradle.kts") },
                     what: "Intermediate CMake/ndk-build output for Android native code.", impact: "Native code recompiles on next build.",
                     restore: { _ in "./gradlew assemble" }),
        ArtifactRule(id: "kotlin", names: [".kotlin"], kind: "Kotlin daemon data", ecosystem: .jvm, risk: .safe,
                     validate: { _, s in has(s, "build.gradle.kts", "settings.gradle.kts", "build.gradle") },
                     what: "Kotlin 2 compiler session data and error logs.", impact: "None.", restore: { _ in "Recreated automatically" }),
        ArtifactRule(id: "pods", names: ["Pods"], kind: "CocoaPods", ecosystem: .apple, risk: .low,
                     validate: { _, s in has(s, "Podfile") },
                     what: "Installed CocoaPods dependencies.", impact: "Xcode builds fail until you reinstall pods.",
                     restore: { _ in "pod install" }),
        ArtifactRule(id: "spm", names: [".build"], kind: "SwiftPM build", ecosystem: .apple, risk: .low,
                     validate: { _, s in has(s, "Package.swift") },
                     what: "Swift Package Manager build products and fetched dependencies.", impact: "Next build re-resolves and recompiles.",
                     restore: { _ in "swift build" }),
        ArtifactRule(id: "dd", names: ["DerivedData"], kind: "Xcode DerivedData", ecosystem: .apple, risk: .safe,
                     validate: { _, _ in true },
                     what: "Project-local Xcode build products and indexes.", impact: "Next Xcode build is a clean build.",
                     restore: { _ in "Build in Xcode" }),
        ArtifactRule(id: "venv", names: [".venv", "venv", "env", ".env", "virtualenv", ".virtualenv"], kind: "Python virtualenv", ecosystem: .python, risk: .low,
                     validate: { d, _ in inside(d, "pyvenv.cfg") },
                     what: "An isolated Python environment with installed packages.",
                     impact: "Scripts using this environment fail until it's recreated. Packages installed by hand (not listed in requirements/lockfile) must be reinstalled manually.",
                     restore: pyRestore),
        ArtifactRule(id: "pycache", names: ["__pycache__"], kind: "Python bytecode", ecosystem: .python, risk: .safe, aggregate: true,
                     validate: { _, _ in true },
                     what: "Compiled .pyc bytecode. Python writes it automatically on import.", impact: "None. Python recreates it on the next import.",
                     restore: { _ in "Automatic" }),
        ArtifactRule(id: "pytools", names: [".pytest_cache", ".mypy_cache", ".ruff_cache", ".hypothesis", ".pytype"], kind: "Python tool cache", ecosystem: .python, risk: .safe, aggregate: true,
                     validate: { _, _ in true },
                     what: "Caches from pytest, mypy, ruff and friends.", impact: "The next type-check or test run is slightly slower.",
                     restore: { _ in "Automatic" }),
        ArtifactRule(id: "tox", names: [".tox", ".nox"], kind: "tox/nox envs", ecosystem: .python, risk: .low,
                     validate: { _, _ in true },
                     what: "Virtualenvs created by tox/nox for test matrices.", impact: "Next tox/nox run recreates them.",
                     restore: { _ in "tox / nox" }),
        ArtifactRule(id: "dart", names: [".dart_tool"], kind: "Dart tool cache", ecosystem: .flutter, risk: .low,
                     validate: { _, s in has(s, "pubspec.yaml") },
                     what: "Dart/Flutter package config and build cache.", impact: "Run pub get before the next build.",
                     restore: { _ in "flutter pub get" }),
        ArtifactRule(id: "terraform", names: [".terraform"], kind: "Terraform providers", ecosystem: .terraform, risk: .low,
                     validate: { _, _ in true },
                     what: "Downloaded Terraform providers and modules.", impact: "Run terraform init before the next plan/apply.",
                     restore: { _ in "terraform init" }),
        ArtifactRule(id: "zig", names: ["zig-cache", ".zig-cache", "zig-out"], kind: "Zig cache", ecosystem: .zig, risk: .low,
                     validate: { _, s in has(s, "build.zig") },
                     what: "Zig build cache/output.", impact: "Recompiles on next build.", restore: { _ in "zig build" }),
        ArtifactRule(id: "stack", names: [".stack-work", "dist-newstyle"], kind: "Haskell build", ecosystem: .haskell, risk: .low,
                     validate: { _, _ in true },
                     what: "Stack/Cabal build output.", impact: "Recompiles on next build.", restore: { _ in "stack build / cabal build" }),
        ArtifactRule(id: "elixir", names: ["_build", "deps"], kind: "Elixir build", ecosystem: .elixir, risk: .low,
                     validate: { _, s in has(s, "mix.exs") },
                     what: "Mix build output and fetched dependencies.", impact: "Run mix deps.get and recompile.",
                     restore: { _ in "mix deps.get && mix compile" }),
        ArtifactRule(id: "bower", names: ["bower_components", "elm-stuff"], kind: "Legacy packages", ecosystem: .node, risk: .low,
                     validate: { _, _ in true },
                     what: "Bower/Elm package installs.", impact: "Reinstall before building.", restore: { _ in "bower install / elm make" }),
        ArtifactRule(id: "composer", names: ["vendor"], kind: "Composer vendor", ecosystem: .php, risk: .low,
                     validate: { _, s in has(s, "composer.json") },
                     what: "PHP dependencies installed by Composer.", impact: "The app won't run until you reinstall.",
                     restore: { _ in "composer install" }),
        ArtifactRule(id: "pnpmstore", names: [".pnpm-store"], kind: "pnpm store", ecosystem: .node, risk: .low,
                     validate: { _, _ in true },
                     what: "A project-local pnpm content store.", impact: "pnpm re-downloads packages on next install.",
                     restore: { _ in "pnpm install" }),
    ]

    static let prefixRules: [ArtifactRule] = [
        ArtifactRule(id: "clion", names: [], prefix: "cmake-build-", kind: "CLion CMake build", ecosystem: .cpp, risk: .low,
                     validate: { _, s in has(s, "CMakeLists.txt") },
                     what: "CLion's CMake build directory.", impact: "Full rebuild next time.", restore: { _ in "Rebuild in CLion" }),
    ]

    static let byName: [String: ArtifactRule] = {
        var m: [String: ArtifactRule] = [:]
        for r in rules { for n in r.names { m[n] = r } }
        return m
    }()

    static let allNames: Set<String> = Set(rules.flatMap(\.names))
}
