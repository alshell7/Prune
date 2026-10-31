import Foundation

@main
enum PruneMain {
    static func main() {
        let args = CommandLine.arguments
        if args.contains("--selftest-features") {
            exit(FeatureSelfTest.run())
        }
        if args.contains("--selftest-volumes") {
            exit(VolumeSelfTest.run())
        }
        if args.contains("--selftest-security") {
            exit(SecuritySelfTest.run())
        }
        if args.contains("--selftest-offload") {
            exit(OffloadSelfTest.run())
        }
        if args.contains("--selftest") {
            exit(SelfTest.run())
        }
        if args.contains("--offload-candidates") {
            let list = OffloadPlanner.candidates(settings: AppSettings.shared.snapshot) { _ in }
            for c in list {
                print(String(format: "%10@  %@  %@%@ — %@", Fmt.bytes(c.bytes) as NSString, c.kind.rawValue.prefix(12).description as NSString,
                             c.title as NSString, c.isGoodCandidate ? " ★" : "", c.note as NSString))
            }
            return
        }
        if args.contains("--security") {
            let started = Date()
            let r = SecurityScanner.run(settings: AppSettings.shared.snapshot) { _ in }
            print("Security check · \(String(format: "%.1f", Date().timeIntervalSince(started)))s · \(r.stats)")
            for p in r.protections { print("  [\(p.on ? "on " : "OFF")] \(p.name): \(p.detail)") }
            let showAll = args.contains("--all")
            for f in r.findings where showAll || !f.inventoryOnly {
                print("\n\(f.severity.label.uppercased())  [\(f.area.rawValue)] \(f.title) — \(f.subtitle)")
                for e in f.evidence.prefix(5) { print("    • \(e.prefix(220))") }
            }
            let inv = r.findings.filter(\.inventoryOnly)
            print("\nInventory (clean): \(inv.count) items · " + Dictionary(grouping: inv, by: \.area).map { "\($0.key.rawValue): \($0.value.count)" }.joined(separator: ", "))
            return
        }
        if args.contains("--secrets") {
            let s = AppSettings.shared.snapshot
            let started = Date()
            let r = SecretsEngine.scan(index: ProjectIndex.build(roots: s.resolvedScanRoots(), settings: s) { _ in }, settings: s)
            print("Secrets · \(String(format: "%.1f", Date().timeIntervalSince(started)))s · \(r.filesChecked) files · \(r.envFiles) env files · \(r.issues.count) issues")
            for f in r.files.sorted(by: { $0.severity > $1.severity }) where args.contains("--all") || f.isIssue {
                print("\n\(f.severity.label.uppercased())  \(FS.tildePath(f.url)) — \(f.origin == .project ? f.git.rawValue : (f.label ?? ""))\(f.pushed ? " · PUSHED" : f.inHistory ? " · in history" : "") — \(f.headline)")
                for h in f.hits.prefix(6) { print(String(format: "    line %-4d %-28@ %-18@ %.2f  %@", h.line, h.kind as NSString, h.masked as NSString, h.confidence, h.why as NSString)) }
            }
            for rc in r.remotes { print("\nMEDIUM  credential in git remote: \(FS.tildePath(rc.project))") }
            if !r.reused.isEmpty { print("\nReused secrets: \(r.reused.count)") }
            return
        }
        if args.contains("--doctor") {
            let s = AppSettings.shared.snapshot
            let issues = ProjectDoctor.scan(index: ProjectIndex.build(roots: s.resolvedScanRoots(), settings: s) { _ in })
            for i in issues { print("\(i.level.label.uppercased())  [\(i.kind.rawValue)] \(i.title) — \(i.detail)\(i.bytes > 0 ? " · \(Fmt.bytes(i.bytes))" : "")\(i.fixLabel.isEmpty ? "" : " → \(i.fixLabel)")") }
            for (old, n) in ProjectDoctor.previousLocations(issues) { print("Moved from \(old): \(n) references") }
            return
        }
        if args.contains("--code-backup") {
            let list = CodeBackup.analyze(settings: AppSettings.shared.snapshot) { _ in }
            for s in list {
                print(String(format: "%-20@ %@%@ — %@", s.level.title as NSString, FS.tildePath(s.path), s.vendored ? " (vendored)" : "", s.headline as NSString))
            }
            return
        }
        if args.contains("--apps") {
            let apps = AppsCatalog.load { _ in }
            for a in apps {
                let move: String = { switch a.move { case .movable: return "movable"; case .caution: return "caution"; case .notMovable: return "stays" } }()
                print(String(format: "%10@  %-26@ %-13@ %-8@ %@", Fmt.bytes(a.totalSize) as NSString, a.name as NSString, a.arch.rawValue as NSString, move as NSString,
                             (a.flags.map(\.rawValue) + a.components.map { $0.kind.rawValue }).joined(separator: ", ") as NSString))
            }
            print("\nAdd-ons:")
            for x in AppsCatalog.addOns(apps: apps, index: AppIndex.build()) {
                print("  [\(x.state)] \(x.kind.rawValue): \(x.name) — \(x.owner ?? "no owner") — \(x.note.prefix(90))")
            }
            return
        }
        if args.contains("--scan") {
            CLI.run(args)
            return
        }
        PruneApp.main()
    }
}
