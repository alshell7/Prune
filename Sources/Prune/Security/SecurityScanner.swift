import Foundation

/// Runs every security analyzer in parallel and merges the results.
enum SecurityScanner {
    static func run(settings: SettingsSnapshot, progress: @escaping (String) -> Void) -> SecurityReport {
        progress("Indexing projects…")
        let idx = ProjectIndex.build(roots: settings.resolvedScanRoots(), settings: settings) { _ in }
        let projectRoots = idx.projects.filter { $0.value.gitKind != .none || idx.outermostProject(for: $0.value.root) == $0.key }.map(\.value.root)
        let nodeModules = idx.artifacts.filter { $0.rule.id == "node_modules" }.map(\.url) + globalNodeModules()
        let sitePackages = pythonSitePackages(venvs: idx.venvs)

        let jobs: [(String, (inout SecurityReport) -> Void)] = [
            ("Background items", { PersistenceAnalyzer.scan(report: &$0) }),
            ("Running processes & network", { ProcessAnalyzer.scan(report: &$0) }),
            ("Protection status", { PostureAnalyzer.scan(report: &$0) }),
            ("Hidden executables", { FileSweepAnalyzer.scan(report: &$0) }),
            ("Browser extensions", { BrowserAnalyzer.scan(report: &$0) }),
            ("npm & Python packages", { PackageAnalyzer.scan(nodeModulesDirs: nodeModules, sitePackages: sitePackages, report: &$0) }),
            ("AI agents & skills", { AIToolsAnalyzer.scan(projectRoots: projectRoots, report: &$0) }),
            ("Project auto-run code", { ProjectThreatAnalyzer.scan(projectRoots: projectRoots, report: &$0) }),
            ("Project credentials", { CredentialsAnalyzer.scan(index: idx, settings: settings, report: &$0) }),
        ]
        var parts: [SecurityReport] = Array(repeating: SecurityReport(), count: jobs.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: jobs.count) { i in
            progress("Checking \(jobs[i].0.lowercased())…")
            var r = SecurityReport()
            jobs[i].1(&r)
            lock.lock(); parts[i] = r; lock.unlock()
        }
        var merged = SecurityReport()
        for p in parts {
            merged.findings += p.findings
            merged.protections += p.protections
            merged.chains.merge(p.chains) { a, _ in a }
            merged.stats.merge(p.stats) { a, _ in a }
            merged.npmPackages.merge(p.npmPackages) { a, _ in a }
        }
        merged.stats["projects"] = projectRoots.count
        if let warning = idx.coverageWarning {
            merged.findings.append(SecurityFinding(id: "projects:coverage", area: .projects, severity: .low,
                title: "Project discovery was incomplete", subtitle: "Some project security checks may be missing", evidence: [warning],
                explanation: "Project-based security checks can only inspect projects discovered in the selected locations.", legitNote: nil,
                recommendation: "Check scan locations, permissions, and deeply nested folders, then scan again.", actions: []))
        }
        merged.findings.sort { ($0.severity, $1.title) > ($1.severity, $0.title) }
        return merged
    }

    static func globalNodeModules() -> [URL] {
        var out: [URL] = []
        for npm in Shell.whichAll("npm") {
            let root = Shell.run(npm, ["root", "-g"], timeout: 15).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if FS.isDir(URL(fileURLWithPath: root)) && !out.contains(where: { $0.path == root }) { out.append(URL(fileURLWithPath: root)) }
        }
        for d in FS.childDirs(FS.home.appendingPathComponent(".npm/_npx")) { let nm = d.appendingPathComponent("node_modules"); if FS.isDir(nm) { out.append(nm) } }
        return out
    }

    static func pythonSitePackages(venvs: [URL]) -> [URL] {
        var roots = venvs
        roots += FS.childDirs(FS.home.appendingPathComponent(".local/share/uv/python")).filter { !FS.isSymlink($0) }
        roots += FS.childDirs(URL(fileURLWithPath: "/Library/Frameworks/Python.framework/Versions")).filter { !FS.isSymlink($0) }
        roots += FS.childDirs(FS.home.appendingPathComponent(".pyenv/versions"))
        var out: [URL] = []
        for r in roots {
            for lib in [r.appendingPathComponent("lib")] {
                for py in FS.childDirs(lib) where py.lastPathComponent.hasPrefix("python") {
                    let sp = py.appendingPathComponent("site-packages")
                    if FS.isDir(sp) { out.append(sp) }
                }
            }
        }
        for v in FS.childDirs(FS.home.appendingPathComponent("Library/Python")) {
            let sp = v.appendingPathComponent("lib/python/site-packages")
            if FS.isDir(sp) { out.append(sp) }
        }
        return out
    }
}
