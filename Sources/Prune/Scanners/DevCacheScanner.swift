import Foundation

struct DevCacheScanner: Scanner {
    let name = "Developer caches"

    struct Rule {
        var path: String
        var title: String
        var eco: Ecosystem?
        var risk: Risk
        var what: String
        var impact: String
        var restore: String? = "Automatic"
        var command: (() -> ShellCommand?)? = nil
    }

    /// Paths this scanner (or the AI scanner) owns. The generic ~/.cache sweep skips them.
    static let claimedCacheNames: Set<String> = [
        "uv", "pip", "puppeteer", "pre-commit", "prisma", "node", "huggingface", "whisper", "torch", "lm-studio",
        "ms-playwright", "gpt4all", "llama.cpp", "selenium", "fontconfig",
    ]

    static func rules() -> [Rule] {
        let go = Shell.which("go")
        let uv = Shell.which("uv")
        let pnpm = Shell.which("pnpm")
        var r: [Rule] = [
            Rule(path: "~/.npm/_cacache", title: "npm cache", eco: .node, risk: .safe,
                 what: "npm's content-addressed download cache. Every package tarball you've ever installed.",
                 impact: "The next npm install re-downloads packages instead of copying them locally."),
            Rule(path: "~/.npm/_npx", title: "npx cache", eco: .node, risk: .safe,
                 what: "Packages fetched to run one-off `npx` commands.", impact: "npx downloads them again the next time."),
            Rule(path: "~/.npm/_logs", title: "npm debug logs", eco: .node, risk: .safe,
                 what: "Debug logs from failed npm runs.", impact: "None."),
            Rule(path: "~/Library/Caches/Yarn", title: "Yarn cache", eco: .node, risk: .safe,
                 what: "Yarn v1's global package cache.", impact: "Yarn re-downloads packages on next install."),
            Rule(path: "~/.yarn/berry/cache", title: "Yarn Berry cache", eco: .node, risk: .safe,
                 what: "Yarn 2+ global package cache.", impact: "Yarn re-downloads packages on next install."),
            Rule(path: "~/.bun/install/cache", title: "Bun cache", eco: .node, risk: .safe,
                 what: "Bun's global package cache.", impact: "Bun re-downloads packages on next install."),
            Rule(path: "~/Library/Caches/deno", title: "Deno cache", eco: .deno, risk: .low,
                 what: "Remote modules and compiled code cached by Deno.", impact: "Deno re-fetches dependencies on next run."),
            Rule(path: "~/.cache/node/corepack", title: "Corepack cache", eco: .node, risk: .low,
                 what: "pnpm/yarn binaries fetched by Corepack.", impact: "Corepack downloads the package manager again on first use."),
            Rule(path: "~/Library/Caches/typescript", title: "TypeScript type cache", eco: .node, risk: .safe,
                 what: "Automatic type acquisition cache used by editors.", impact: "Editors re-download @types on demand."),
            Rule(path: "~/Library/Caches/electron", title: "Electron binaries", eco: .node, risk: .low,
                 what: "Electron runtime zips downloaded by electron/electron-builder.", impact: "Re-downloaded on next install of an Electron project."),
            Rule(path: "~/Library/Caches/electron-builder", title: "electron-builder cache", eco: .node, risk: .low,
                 what: "Packaging tools (NSIS, dmg-builder, etc.).", impact: "Re-downloaded on next package build."),
            Rule(path: "~/Library/Caches/ms-playwright", title: "Playwright browsers", eco: .node, risk: .low,
                 what: "Chromium, Firefox and WebKit builds downloaded for Playwright tests.", impact: "E2E tests fail until you reinstall browsers.",
                 restore: "npx playwright install"),
            Rule(path: "~/.cache/puppeteer", title: "Puppeteer browsers", eco: .node, risk: .low,
                 what: "Chrome for Testing builds downloaded by Puppeteer.", impact: "Puppeteer downloads Chrome again on next install.",
                 restore: "npx puppeteer browsers install chrome"),
            Rule(path: "~/Library/Caches/Cypress", title: "Cypress binaries", eco: .node, risk: .low,
                 what: "Cypress app binaries, one per version.", impact: "Cypress re-downloads on next install.", restore: "npx cypress install"),
            Rule(path: "~/.cache/prisma", title: "Prisma engines", eco: .node, risk: .low,
                 what: "Prisma query/schema engine binaries.", impact: "Re-downloaded on next prisma generate."),
            Rule(path: "~/Library/Caches/pip", title: "pip cache", eco: .python, risk: .safe,
                 what: "Wheels and HTTP responses cached by pip.", impact: "pip re-downloads packages on next install."),
            Rule(path: "~/.cache/pip", title: "pip cache (XDG)", eco: .python, risk: .safe,
                 what: "Wheels cached by pip.", impact: "pip re-downloads packages on next install."),
            Rule(path: "~/Library/Caches/pypoetry", title: "Poetry cache", eco: .python, risk: .safe,
                 what: "Poetry's package and artifact cache.", impact: "Poetry re-downloads on next install."),
            Rule(path: "~/Library/Caches/pipenv", title: "Pipenv cache", eco: .python, risk: .safe,
                 what: "Pipenv's package cache.", impact: "Re-downloaded on next install."),
            Rule(path: "~/.cache/pre-commit", title: "pre-commit environments", eco: .python, risk: .low,
                 what: "Hook environments created by pre-commit.", impact: "The next commit rebuilds hook environments (slow once)."),
            Rule(path: "~/.cargo/registry/cache", title: "Cargo crate archives", eco: .rust, risk: .safe,
                 what: "Downloaded .crate files for every dependency version you've built.", impact: "Cargo re-downloads crates on next build."),
            Rule(path: "~/.cargo/registry/src", title: "Cargo extracted sources", eco: .rust, risk: .safe,
                 what: "Unpacked crate sources. Cargo re-extracts them from the archives as needed.", impact: "Re-extracted on next build."),
            Rule(path: "~/.cargo/registry/index", title: "Cargo registry index", eco: .rust, risk: .low,
                 what: "Local copy of the crates.io index.", impact: "Cargo refetches the index on next build."),
            Rule(path: "~/.cargo/git/checkouts", title: "Cargo git checkouts", eco: .rust, risk: .safe,
                 what: "Working copies of git dependencies.", impact: "Re-checked out from the git db on next build."),
            Rule(path: "~/.cargo/git/db", title: "Cargo git database", eco: .rust, risk: .low,
                 what: "Bare clones of git dependencies.", impact: "Re-cloned on next build."),
            Rule(path: "~/.rustup/downloads", title: "rustup downloads", eco: .rust, risk: .safe,
                 what: "Leftover toolchain component downloads.", impact: "None."),
            Rule(path: "~/.rustup/tmp", title: "rustup temp", eco: .rust, risk: .safe, what: "Temporary files from rustup.", impact: "None."),
            Rule(path: "~/.gradle/caches/modules-2", title: "Gradle dependency cache", eco: .jvm, risk: .low,
                 what: "Every Maven/Google artifact Gradle downloaded (AndroidX, Kotlin, Compose, Firebase…). Usually the biggest Gradle folder.",
                 impact: "The next Gradle build re-downloads all dependencies, which can take several minutes and needs network access."),
            Rule(path: "~/.gradle/daemon", title: "Gradle daemon logs", eco: .jvm, risk: .safe,
                 what: "Logs and registries from Gradle daemons.", impact: "None. A new daemon starts on the next build."),
            Rule(path: "~/.gradle/.tmp", title: "Gradle temp", eco: .jvm, risk: .safe, what: "Gradle temporary files.", impact: "None."),
            Rule(path: "~/.m2/repository", title: "Maven repository", eco: .jvm, risk: .low,
                 what: "Maven's local artifact repository.", impact: "Maven re-downloads dependencies on next build.",
                 restore: "mvn dependency:resolve"),
            Rule(path: "~/.ivy2/cache", title: "Ivy cache", eco: .jvm, risk: .low, what: "Ivy/sbt dependency cache.", impact: "Re-downloaded on next build."),
            Rule(path: "~/Library/Caches/Coursier", title: "Coursier cache", eco: .jvm, risk: .low, what: "Scala/Coursier artifact cache.", impact: "Re-downloaded on next build."),
            Rule(path: "~/.android/cache", title: "Android tools cache", eco: .android, risk: .safe, what: "SDK Manager/AVD Manager download cache.", impact: "None."),
            Rule(path: "~/.android/build-cache", title: "Android build cache", eco: .android, risk: .safe, what: "Legacy Android Gradle Plugin build cache.", impact: "None."),
            Rule(path: "~/Library/Caches/CocoaPods", title: "CocoaPods cache", eco: .apple, risk: .safe,
                 what: "Downloaded pod sources.", impact: "pod install re-downloads pods."),
            Rule(path: "~/.cocoapods/repos", title: "CocoaPods spec repos", eco: .apple, risk: .low,
                 what: "Cloned spec repositories. Modern CocoaPods uses the CDN, so the old master repo is rarely needed.",
                 impact: "CocoaPods uses the CDN or re-clones on next pod install.", restore: "pod repo update"),
            Rule(path: "~/Library/Caches/org.carthage.CarthageKit", title: "Carthage cache", eco: .apple, risk: .safe,
                 what: "Carthage dependency cache.", impact: "Re-downloaded on next carthage bootstrap."),
            Rule(path: "~/Library/Caches/org.swift.swiftpm", title: "SwiftPM cache", eco: .apple, risk: .safe,
                 what: "Swift Package Manager repository and manifest cache.", impact: "Packages are re-fetched on next resolve."),
            Rule(path: "~/.pub-cache", title: "Dart/Flutter pub cache", eco: .flutter, risk: .low,
                 what: "Packages downloaded by pub.", impact: "flutter pub get re-downloads packages.", restore: "flutter pub get"),
            Rule(path: "~/.composer/cache", title: "Composer cache", eco: .php, risk: .safe, what: "Composer package cache.", impact: "Re-downloaded on next install."),
            Rule(path: "~/Library/Caches/composer", title: "Composer cache", eco: .php, risk: .safe, what: "Composer package cache.", impact: "Re-downloaded on next install."),
            Rule(path: "~/.terraform.d/plugin-cache", title: "Terraform plugin cache", eco: .terraform, risk: .low,
                 what: "Shared provider plugin cache.", impact: "terraform init re-downloads providers."),
            Rule(path: "~/Library/Caches/ccache", title: "ccache", eco: .cpp, risk: .safe, what: "C/C++ compiler cache.", impact: "The next builds compile from scratch."),
            Rule(path: "~/.ccache", title: "ccache", eco: .cpp, risk: .safe, what: "C/C++ compiler cache.", impact: "The next builds compile from scratch."),
            Rule(path: "~/Library/Caches/Mozilla.sccache", title: "sccache", eco: .rust, risk: .safe, what: "Shared compilation cache.", impact: "The next builds compile from scratch."),
            Rule(path: "~/.espressif/dist", title: "ESP-IDF downloads", eco: .esp, risk: .safe,
                 what: "Archives of ESP-IDF tools that have already been extracted.", impact: "None, unless you reinstall offline."),
        ]
        r.append(Rule(path: "~/Library/Caches/go-build", title: "Go build cache", eco: .go, risk: .safe,
                      what: "Compiled package objects and test results.", impact: "The next go build/test recompiles.",
                      command: { go.map { ShellCommand(tool: $0, args: ["clean", "-cache"]) } }))
        if let go {
            let modcache = Shell.run(go, ["env", "GOMODCACHE"], timeout: 10).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !modcache.isEmpty {
                r.append(Rule(path: modcache, title: "Go module cache", eco: .go, risk: .low,
                              what: "Source of every Go module version you've downloaded (plus auto-downloaded Go toolchains). Files are read-only, so `go clean` is used.",
                              impact: "The next go build re-downloads modules.", restore: "go mod download",
                              command: { ShellCommand(tool: go, args: ["clean", "-modcache"]) }))
            }
        }
        r.append(Rule(path: "~/.cache/uv", title: "uv cache", eco: .python, risk: .low,
                      what: "uv's wheel and source cache. It is shared by every uv-managed project.",
                      impact: "uv re-downloads wheels the next time you sync or install. Existing virtualenvs keep working.",
                      restore: "uv sync", command: { uv.map { ShellCommand(tool: $0, args: ["cache", "clean"]) } }))
        for store in ["~/Library/pnpm/store", "~/.local/share/pnpm/store", "~/.pnpm-store"] {
            r.append(Rule(path: store, title: "pnpm store", eco: .node, risk: pnpm == nil ? .low : .safe,
                          what: "pnpm's global content-addressable store. Projects hard-link packages from here.",
                          impact: pnpm == nil ? "pnpm re-downloads packages on next install." : "`pnpm store prune` removes only packages no project references.",
                          command: { pnpm.map { ShellCommand(tool: $0, args: ["store", "prune"]) } }))
        }
        return r
    }

    func scan(_ ctx: ScanContext, _ progress: ScanProgress) -> [CleanupItem] {
        var items: [CleanupItem] = []
        let rules = Self.rules()
        progress.update("Measuring \(rules.count) cache locations…")
        let existing = rules.filter { FS.exists(ctx.url($0.path)) }
        let sizes = Sizer.measureMany(existing.map { ctx.url($0.path) })
        for rule in existing {
            let u = ctx.url(rule.path)
            let action: CleanupAction = rule.command?().map { .command($0) } ?? .removeFiles
            if var i = ctx.cacheItem(.devCaches, path: rule.path, title: rule.title, subtitle: FS.tildePath(u), ecosystem: rule.eco,
                                     risk: rule.risk, what: rule.what, impact: rule.impact, restore: rule.restore, action: action,
                                     measuredSize: sizes[u]?.bytes) {
                i.lastUsed = sizes[u]?.newest
                items.append(i)
            }
        }

        // Gradle's transform/jar/build caches (names carry version numbers).
        let gradleCaches = FS.home.appendingPathComponent(".gradle/caches")
        let transient = FS.childDirs(gradleCaches).filter { n in ["transforms-", "jars-", "build-cache-", "journal-", "kotlin-dsl"].contains { n.lastPathComponent.hasPrefix($0) } }
        if !transient.isEmpty {
            let m = Sizer.measureMany(transient)
            let total = m.values.reduce(0) { $0 + $1.bytes }
            if total >= ctx.minBytes {
                let status = ctx.ecosystemStatus(.jvm)
                items.append(CleanupItem(
                    category: .devCaches, title: "Gradle transform & build caches", subtitle: "\(transient.count) folders in ~/.gradle/caches", group: Ecosystem.jvm.title,
                    paths: transient, size: total, risk: .safe, recommendation: status.stale ? .recommended : .optional,
                    reason: status.stale ? "Regenerates automatically. " + status.note : status.note,
                    whatItIs: "Transformed AARs/JARs (dexed, desugared, jetified) and Gradle's local build cache.",
                    impact: "The first build of each project spends extra time re-transforming dependencies.",
                    restore: "Automatic", lastUsed: m.values.compactMap(\.newest).max()))
            }
        }

        // Anything else in ~/.cache (XDG says its contents are disposable).
        let xdg = FS.home.appendingPathComponent(".cache")
        let others = FS.childDirs(xdg).filter { !Self.claimedCacheNames.contains($0.lastPathComponent) }
        let om = Sizer.measureMany(others)
        for d in others {
            guard let m = om[d], m.bytes >= max(ctx.minBytes, 20 * 1_048_576) else { continue }
            let days = Age.days(m.newest) ?? 999
            items.append(CleanupItem(
                category: .devCaches, title: "~/.cache/\(d.lastPathComponent)", subtitle: "Tool cache", group: "Other tools",
                paths: [d], size: m.bytes, risk: .low, recommendation: days >= ctx.staleDays ? .recommended : .optional,
                reason: days >= ctx.staleDays ? "Not written to in \(Fmt.age(m.newest))." : "Updated \(days == 0 ? "today" : Fmt.age(m.newest) + " ago"), so a tool is using it.",
                whatItIs: "A cache folder created by a command-line tool. By the XDG convention, ~/.cache only holds data that can be recreated.",
                whyKeep: days < ctx.staleDays ? "The tool that owns it will re-download or rebuild what it needs, which may be slow the first time." : nil,
                impact: "The owning tool recreates what it needs on next use.", restore: "Automatic", lastUsed: m.newest))
        }

        // React Native / Metro caches in the per-user temp folder.
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
        let metro = FS.children(tmp).filter { u in ["metro-", "haste-map-", "react-native-packager-cache-"].contains { u.lastPathComponent.hasPrefix($0) } && FS.isDir(u) }
        if !metro.isEmpty {
            let mm = Sizer.measureMany(metro)
            let total = mm.values.reduce(0) { $0 + $1.bytes }
            if total >= ctx.minBytes {
                items.append(CleanupItem(
                    category: .devCaches, title: "Metro bundler caches", subtitle: "\(metro.count) folders in $TMPDIR", group: Ecosystem.node.title,
                    paths: metro, size: total, risk: .safe, recommendation: .recommended, reason: "Regenerates automatically.",
                    whatItIs: "Transform and haste-map caches from React Native's Metro bundler.",
                    impact: "The next Metro start is slower (the same as `--reset-cache`).", restore: "Automatic",
                    lastUsed: mm.values.compactMap(\.newest).max()))
            }
        }
        return items
    }
}
