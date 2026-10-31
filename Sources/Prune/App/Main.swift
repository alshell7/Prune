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
