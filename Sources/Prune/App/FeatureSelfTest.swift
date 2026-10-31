import Foundation

/// Exercises the disk, credential, duplicate and PlugInKit logic using disposable fixtures.
enum FeatureSelfTest {
    static func run() -> Int32 {
        SelfTest.failures = 0
        AuditLog.enabled = false
        let fm = FileManager.default
        let base = FS.home.appendingPathComponent("Library/Caches/PruneFeatureTest-\(getpid())")
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        func write(_ url: URL, _ data: Data) {
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url)
        }
        func text(_ url: URL, _ value: String) { write(url, Data(value.utf8)) }
        let primary = base.appendingPathComponent("Primary"), external = base.appendingPathComponent("External Drive")
        let primaryProject = primary.appendingPathComponent("local-project"), project = external.appendingPathComponent("external-project")
        text(primaryProject.appendingPathComponent("package.json"), "{}")
        text(project.appendingPathComponent("package.json"), "{}")
        text(project.appendingPathComponent(".gitignore"), ".env.local\n")
        let secret = "v9F1m7Q2t8R4n6Z3p5K0x1L2"
        text(project.appendingPathComponent(".env"), "API_KEY=\(secret)\n")
        text(project.appendingPathComponent(".env.local"), "DATABASE_PASSWORD=\(secret)\n")
        text(project.appendingPathComponent(".env.example"), "API_KEY=replace_me\n")
        text(project.appendingPathComponent("public/config.js"), "const api_key = '\(secret)';\n")
        text(project.appendingPathComponent("safe.js"), "const api_key = process.env.API_KEY;\n")
        write(project.appendingPathComponent("node_modules/pkg/index.js"), Data(repeating: 0x31, count: 1_200_000))
        write(project.appendingPathComponent("video.dat"), Data(repeating: 0x32, count: 1_200_000))
        _ = Git.run(project, ["init", "-q"])
        _ = Git.run(project, ["add", "--", ".env", ".env.example", ".gitignore", "package.json", "public/config.js"])

        var settings = AppSettings.shared.snapshot
        settings.scanRoots = [primary]
        settings.includeExternalVolumes = true
        settings.excludedVolumes = []
        settings.excludedPaths = []
        settings.largeFileMB = 1
        settings.minItemMB = 1

        print("External disks and projects")
        let roots = settings.resolvedScanRoots(externalVolumes: [external, external])
        SelfTest.check("selected external volume included once", roots.filter { $0 == external }.count == 1)
        let index = ProjectIndex.build(roots: roots, settings: settings, largeFileRoots: [external]) { _ in }
        SelfTest.check("indexes project on external volume", index.projects[project.path] != nil)
        SelfTest.check("finds external project artifact", index.artifacts.contains { $0.url.path == project.appendingPathComponent("node_modules").path })
        SelfTest.check("finds external large file without Spotlight", index.largeFiles.contains(project.appendingPathComponent("video.dat")))
        let backup = CodeBackup.analyze(settings: settings, externalVolumes: [external]) { _ in }
        SelfTest.check("code backup includes external project", backup.contains { $0.path.path == project.path && $0.level == .noRemote },
                       backup.map { "\($0.path.path): \($0.level.title)" }.joined(separator: ", "))
        _ = Git.run(project, ["-c", "user.email=test@invalid", "-c", "user.name=Test", "commit", "-qm", "fixture"])
        let worktree = external.appendingPathComponent("linked-worktree")
        let added = Git.run(project, ["worktree", "add", "-q", "-b", "fixture-branch", worktree.path])
        let worktreeStatus = CodeBackup.gitStatus(worktree, linked: true)
        SelfTest.check("linked worktree with no remote is not called backed up", added.ok && worktreeStatus.level == .noRemote)
        SelfTest.check("git errors are not called backed up", CodeBackup.gitStatus(external.appendingPathComponent("missing-repo"), linked: false).level == .unknown)
        let remote = CodeBackup.sanitizedRemote("https://token:secret@github.com/owner/repo.git?access_token=hidden")
        SelfTest.check("remote URLs do not expose embedded credentials", !remote.contains("token") && !remote.contains("secret") && remote.contains("github.com"))
        SelfTest.check("scp-style remote user information is hidden", CodeBackup.sanitizedRemote("secret@host.invalid:owner/repo") == "host.invalid:owner/repo")
        var excluded = settings
        excluded.excludedVolumes = [external.path]
        SelfTest.check("excluded volume and descendants are excluded", !excluded.resolvedScanRoots(externalVolumes: [external]).contains(external) && excluded.isExcluded(project))
        excluded.includeExternalVolumes = false
        excluded.scanRoots = [external]
        SelfTest.check("explicit root cannot bypass an excluded volume", excluded.resolvedScanRoots(externalVolumes: []).isEmpty)
        let overlap = ProjectIndex.build(roots: [external, project], settings: settings) { _ in }
        SelfTest.check("overlapping roots are indexed only once", overlap.artifacts.filter { $0.url == project.appendingPathComponent("node_modules") }.count == 1)
        var excludedMarkers = settings
        excludedMarkers.excludedPaths = [project.appendingPathComponent("package.json").path, project.appendingPathComponent(".git").path]
        let withoutMarkers = ProjectIndex.build(roots: [external], settings: excludedMarkers) { _ in }
        SelfTest.check("excluded files do not identify a project", withoutMarkers.projects[project.path] == nil)
        let readOnly = VolumeInfo(url: external, name: "Fixture", total: 10, available: 5, availableStrict: 5, isInternal: false, isBoot: false, readOnly: true)
        let item = CleanupItem(category: .largeFiles, title: "test", paths: [project.appendingPathComponent("video.dat")], size: 100, risk: .review,
                               recommendation: .optional, reason: "", whatItIs: "", impact: "")
        SelfTest.check("read-only disk findings cannot be cleaned", !ScanContext.markReadOnly([item], volumes: [readOnly])[0].isActionable)
        var localItem = item; localItem.paths = [primaryProject.appendingPathComponent("file")]; localItem.size = 200; localItem.recommendation = .recommended
        var externalItem = item; externalItem.recommendation = .recommended
        let startup = VolumeInfo(url: URL(fileURLWithPath: "/"), name: "Startup", total: 1000, available: 500, availableStrict: 500, isInternal: true, isBoot: true)
        let totals = AppModel.volumeTotals([localItem, externalItem], volumes: [startup, readOnly])
        SelfTest.check("per-volume totals do not credit external files to the startup disk", totals["/"]?.recommended == 200 && totals[external.path]?.recommended == 100)
        let links = base.appendingPathComponent("link-sizing"), one = links.appendingPathComponent("one"), two = links.appendingPathComponent("two")
        write(one.appendingPathComponent("data"), Data(repeating: 0x51, count: 128_000))
        try? fm.createDirectory(at: two, withIntermediateDirectories: true)
        try? fm.linkItem(at: one.appendingPathComponent("data"), to: two.appendingPathComponent("data"))
        let sizes = Sizer.measureMany([one, two])
        SelfTest.check("hardlinks are counted independently for separate size requests", sizes[one]?.files == 1 && sizes[two]?.files == 1)
        SelfTest.check("hardlinks are counted once within one size request", Sizer.measure(links).files == 1)

        print("Credential detection")
        var security = SecurityReport()
        CredentialsAnalyzer.scan(index: index, settings: settings, report: &security)
        let envFinding = security.findings.first { $0.id == "credentials:" + project.appendingPathComponent(".env").path }
        SelfTest.check("tracked .env with a credential is high severity", envFinding?.severity == .high && envFinding?.evidence.contains("File is tracked by git.") == true)
        let ignored = security.findings.first { $0.id == "credentials:" + project.appendingPathComponent(".env.local").path }
        SelfTest.check("ignored .env reported with its git status", ignored?.severity == .low && ignored?.evidence.contains("File is ignored by git.") == true)
        let example = security.findings.first { $0.id == "credentials:" + project.appendingPathComponent(".env.example").path }
        SelfTest.check("placeholder example is inventory, not a secret", example?.inventoryOnly == true)
        let publicFile = security.findings.first { $0.id == "credentials:" + project.appendingPathComponent("public/config.js").path }
        SelfTest.check("hard-coded credential under public is high severity", publicFile?.severity == .high && publicFile?.evidence.contains(where: { $0.contains("public web folder") }) == true)
        SelfTest.check("environment-variable references are not flagged", !security.findings.contains { $0.paths.contains(project.appendingPathComponent("safe.js").path) })
        SelfTest.check("credential values are absent from findings", !String(describing: security.findings).contains(secret))
        SelfTest.check("private key markers are detected", CredentialsAnalyzer.signals(in: "-----BEGIN PRIVATE KEY-----\n").contains { $0.kind == "Private key" })
        SelfTest.check("common placeholders are ignored", CredentialsAnalyzer.signals(in: "API_KEY=your_api_key_here\nTOKEN=${TOKEN}\n").isEmpty)
        let camel = CredentialsAnalyzer.signals(in: "let x = 1\nconst accessToken = '\(secret)'\n")
        SelfTest.check("camel-case credentials report the correct line", camel.contains { $0.kind == "Hard-coded credential" && $0.line == 2 })
        SelfTest.check("well-known token formats are detected", CredentialsAnalyzer.signals(in: "ghp_9N2ABc4Qx7Wv8Te3Yq6Rk5Lm0Fs1Zp4Hj9Ud\n").contains { $0.kind == "GitHub token" })
        _ = Git.run(project, ["remote", "add", "origin", "https://user:\(secret)@example.invalid/repo.git"])
        var remoteSecurity = SecurityReport()
        CredentialsAnalyzer.scan(index: index, settings: settings, report: &remoteSecurity)
        SelfTest.check("credential-bearing Git remotes are identified without revealing their values",
                       remoteSecurity.findings.contains { $0.id == "credentials:remote:" + project.path } && !String(describing: remoteSecurity.findings).contains(secret))

        print("Duplicate files")
        let dupDir = base.appendingPathComponent("duplicate-fixtures")
        var bytes = Data(repeating: 0x61, count: 800_000)
        let a = dupDir.appendingPathComponent("a.bin"), b = dupDir.appendingPathComponent("b.bin"), c = dupDir.appendingPathComponent("c.bin")
        write(a, bytes); write(b, bytes); bytes[100_000] = 0x62; write(c, bytes)
        try? fm.linkItem(at: a, to: dupDir.appendingPathComponent("hardlink.bin"))
        try? fm.createSymbolicLink(atPath: dupDir.appendingPathComponent("symlink.bin").path, withDestinationPath: a.path)
        let duplicates = DuplicateFinder.scan(settings: settings, roots: [dupDir], minimum: 1, budget: 10_000_000) { _ in }
        let copies = duplicates.groups.flatMap(\.files)
        SelfTest.check("full hashes distinguish files with identical samples", duplicates.groups.count == 1 && copies.count == 2 && !copies.contains { $0.url == c })
        SelfTest.check("hardlinks and symlinks do not count as extra copies", !copies.contains { $0.url.lastPathComponent == "symlink.bin" } && copies.count == 2)
        let limited = DuplicateFinder.scan(settings: settings, roots: [dupDir], minimum: 1, budget: 1) { _ in }
        SelfTest.check("verification budget reports an incomplete scan", limited.incomplete && limited.skippedForBudget > 0)
        if let group = duplicates.groups.first, group.files.count == 2 {
            write(group.files[0].url, Data(repeating: 0x35, count: 800_000))
            let result = DuplicateFinder.trash(group.files[0], keeping: group.files[1])
            SelfTest.check("changed copies are never moved to Trash", !result.0 && FS.exists(group.files[0].url) && FS.exists(group.files[1].url))
        }

        print("Dangling app extensions")
        let missing = base.appendingPathComponent("Gone.app/Contents/PlugIns/Gone.appex").path
        let id = "local.prune.fixture.extension"
        func registration(_ path: String, ignored: Bool = false) -> String {
            "\(ignored ? "-" : "+")    \(id)(1)\n            Path = \(path)\n"
        }
        SelfTest.check("parses enabled and disabled PlugInKit records", PluginRegistry.parse(registration(missing) + registration(missing + "2", ignored: true)).map(\.ignored) == [false, true])
        let installedHost = base.appendingPathComponent("StillInstalled.app")
        try? fm.createDirectory(at: installedHost, withIntermediateDirectories: true)
        let oldPath = installedHost.appendingPathComponent("Contents/PlugIns/Old.appex").path
        let stale = PluginRegistry.staleAddOns(registration(oldPath), mounted: [])
        SelfTest.check("finds a missing extension even when its host app remains installed", stale.count == 1 && stale.first?.owner == "StillInstalled")
        let addon = AddOn(kind: .appExtension, name: id, path: missing, bundleID: id, owner: nil, state: .dangling, note: "")
        var disabled = false
        let result = PluginRegistry.removeStale(addon, mounted: []) { args in
            if args[0] == "-mADvv" { return ShellResult(status: 0, stdout: registration(missing, ignored: disabled), stderr: "") }
            if args[0] == "-e" { disabled = true; return ShellResult(status: 0, stdout: "", stderr: "") }
            return ShellResult(status: 1, stdout: "", stderr: "no plugin at missing path")
        }
        if case .disabled? = result.0 { SelfTest.check("missing bundle falls back to verified disable", disabled) }
        else { SelfTest.check("missing bundle falls back to verified disable", false, result.1) }
        let live = base.appendingPathComponent("Live.appex")
        try? fm.createDirectory(at: live, withIntermediateDirectories: true)
        var attemptedChange = false
        let protected = PluginRegistry.removeStale(addon, mounted: []) { args in
            if args[0] == "-mADvv" { return ShellResult(status: 0, stdout: registration(missing) + registration(live.path), stderr: "") }
            attemptedChange = true; return ShellResult(status: 0, stdout: "", stderr: "")
        }
        SelfTest.check("never disables an installed duplicate", protected.0 == nil && !attemptedChange)
        let unknownOutput = PluginRegistry.removeStale(addon, mounted: []) { _ in ShellResult(status: 0, stdout: "Unexpected output", stderr: "") }
        SelfTest.check("unrecognized registry output is not reported as removal", unknownOutput.0 == nil)
        var offline = addon; offline.path = "/Volumes/Disconnected/Gone.appex"
        let disconnected = PluginRegistry.removeStale(offline, mounted: []) { _ in attemptedChange = true; return ShellResult(status: 0, stdout: "", stderr: "") }
        SelfTest.check("disconnected drive is not treated as dangling", disconnected.0 == nil && !attemptedChange)

        print(SelfTest.failures == 0 ? "\nAll feature checks passed." : "\n\(SelfTest.failures) feature check(s) failed.")
        return SelfTest.failures == 0 ? 0 : 1
    }
}
