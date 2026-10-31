import Foundation

/// Uses only a disposable fixture in the current workspace, on its already-mounted external volume.
enum VolumeSelfTest {
    static func run() -> Int32 {
        SelfTest.failures = 0
        AuditLog.enabled = false
        let fm = FileManager.default
        let workspace = URL(fileURLWithPath: fm.currentDirectoryPath).standardizedFileURL
        guard let volume = SystemInfo.volumes().filter({ !$0.isBoot && ($0.url.path == workspace.path || FS.isAncestor($0.url.path, of: workspace.path)) })
            .max(by: { $0.url.path.count < $1.url.path.count }) else {
            SelfTest.check("workspace is on a mounted external volume", false, "Run this check from a workspace on a mounted external disk.")
            return 1
        }
        let fixture = workspace.appendingPathComponent(".prune-volume-test-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: fixture) }
        let project = fixture.appendingPathComponent("drive-project")
        do {
            try fm.createDirectory(at: project.appendingPathComponent("node_modules/pkg"), withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: project.appendingPathComponent("package.json"))
            try Data("API_KEY=replace_me\n".utf8).write(to: project.appendingPathComponent(".env"))
            try Data(repeating: 0x61, count: 1_500_000).write(to: project.appendingPathComponent("node_modules/pkg/index.js"))
            try Data(repeating: 0x62, count: 1_500_000).write(to: project.appendingPathComponent("video.dat"))
        } catch { SelfTest.check("create test fixture", false, error.localizedDescription); return 1 }

        // Keep the test confined to its own folder even though selection starts at the actual mount root.
        var exclusions: [String] = []
        let relative = String(fixture.path.dropFirst(volume.url.path.count)).split(separator: "/").map(String.init)
        var parent = volume.url
        for component in relative {
            exclusions += FS.children(parent).filter { $0.lastPathComponent != component }.map(\.path)
            parent.appendPathComponent(component)
        }
        var settings = AppSettings.shared.snapshot
        settings.scanRoots = []
        settings.includeExternalVolumes = true
        settings.excludedVolumes = SystemInfo.externalVolumeRoots().filter { $0.path != volume.url.path }.map(\.path)
        settings.excludedPaths = exclusions
        settings.minItemMB = 1
        settings.largeFileMB = 1
        let ctx = ScanContext(settings: settings)
        SelfTest.check("discovers the mounted workspace drive automatically", ctx.scanRoots.contains { $0.path == volume.url.path })
        let idx = ctx.projects()
        SelfTest.check("indexes the external-drive fixture", idx.projects[project.path] != nil)
        SelfTest.check("excludes unrelated workspace projects", idx.projects.keys.allSatisfy { $0 == fixture.path || FS.isAncestor(fixture.path, of: $0) })
        let artifacts = ProjectArtifactScanner().scan(ctx, ScanProgress { _ in })
        SelfTest.check("suggests and measures an external project artifact", artifacts.contains { $0.paths.contains(where: { $0.path == project.appendingPathComponent("node_modules").path }) && $0.size >= 1_500_000 })
        SelfTest.check("finds an external large file without Spotlight", idx.largeFiles.contains { $0.path == project.appendingPathComponent("video.dat").path })
        let backup = CodeBackup.analyze(settings: settings) { _ in }
        SelfTest.check("code backup checks the external project", backup.contains { $0.path.path == project.path && $0.level == .noGit })
        var report = SecurityReport()
        CredentialsAnalyzer.scan(index: idx, settings: settings, report: &report)
        SelfTest.check("credential inventory includes the external project", report.findings.contains { $0.paths.contains(project.appendingPathComponent(".env").path) })
        var excluded = settings; excluded.excludedVolumes.append(volume.url.path)
        let excludedContext = ScanContext(settings: excluded)
        SelfTest.check("disabled external disk is not scanned", !excludedContext.projects().projects.keys.contains(project.path))
        var bootOnly = settings; bootOnly.scanRoots = [URL(fileURLWithPath: "/")]; bootOnly.includeExternalVolumes = false
        bootOnly.excludedPaths = []; bootOnly.excludedVolumes = []
        SelfTest.check("a startup-root scan does not admit Spotlight results from unselected disks", !ScanContext(settings: bootOnly).includesExternalFile(project.appendingPathComponent("video.dat").path))
        print(SelfTest.failures == 0 ? "\nAll mounted-volume checks passed." : "\n\(SelfTest.failures) mounted-volume check(s) failed.")
        return SelfTest.failures == 0 ? 0 : 1
    }
}
