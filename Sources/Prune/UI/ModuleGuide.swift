import SwiftUI

// MARK: - Catalog

/// One animated "how it works" scene: tokens travel from a source, through Prune's engine, to one of the outcomes.
struct ExplainerScene {
    struct Node { var symbol: String; var label: String; var tint: Color = .secondary }
    struct Token { var symbol: String; var tint: Color; var output: Int }
    enum Effect { case scan, shield, filter, sync, pulse }
    var source: Node
    var engine: Node
    var effect: Effect
    var outputs: [Node]
    var tokens: [Token]
}

struct ModuleInfo {
    var key: String
    var title: String
    var tagline: String
    var symbol: String
    var tint: Color
    var steps: [String]
    var scene: ExplainerScene
}

extension Route {
    var guideKey: String {
        switch self {
        case .overview: "overview"
        case .category: "cleanup"
        case .explorer: "explorer"
        case .systemData: "systemData"
        case .offload: "offload"
        case .security: "security"
        case .codeBackup: "codeBackup"
        case .taskManager: "taskManager"
        case .network: "network"
        case .apps: "apps"
        case .duplicates: "duplicates"
        case .secrets: "secrets"
        case .doctor: "doctor"
        case .maintenance: "maintenance"
        case .timeline: "timeline"
        case .watched: "watched"
        case .history: "history"
        }
    }
}

@MainActor
@Observable
final class ModuleGuide {
    static let shared = ModuleGuide()
    private let d = UserDefaults.standard
    var dismissed: Set<String>
    var forced: String?
    var showTour = false

    private init() {
        dismissed = Set(UserDefaults.standard.stringArray(forKey: "guideDismissed") ?? [])
        showTour = !UserDefaults.standard.bool(forKey: "didShowTour") && UserDefaults.standard.string(forKey: "PruneRoute") == nil
    }

    static func noteVisit(_ route: Route) { if shared.forced != route.guideKey { shared.forced = nil } }

    func isVisible(_ route: Route) -> Bool { forced == route.guideKey || !dismissed.contains(route.guideKey) }

    func dismiss(_ route: Route) {
        withAnimation(.snappy) {
            dismissed.insert(route.guideKey)
            if forced == route.guideKey { forced = nil }
        }
        d.set(Array(dismissed), forKey: "guideDismissed")
    }

    func toggle(_ route: Route) {
        withAnimation(.snappy) {
            if isVisible(route) { dismiss(route) } else { forced = route.guideKey }
        }
    }

    func finishTour() { showTour = false; d.set(true, forKey: "didShowTour") }

    static func info(_ key: String) -> ModuleInfo { catalog.first { $0.key == key } ?? catalog[0] }

    typealias N = ExplainerScene.Node
    typealias T = ExplainerScene.Token

    static let catalog: [ModuleInfo] = [
        ModuleInfo(key: "overview", title: "Overview", tagline: "Every disk, what fills it, and what's safe to reclaim.", symbol: "gauge.with.dots.needle.33percent", tint: .accentColor,
                   steps: ["Prune walks your projects, caches and apps on every analyzed disk", "Each finding is checked against git and your build files", "You review a short, explained list. Nothing is deleted without you"],
                   scene: .init(source: N(symbol: "internaldrive.fill", label: "Your disks"), engine: N(symbol: "sparkle.magnifyingglass", label: "Analyze", tint: .accentColor), effect: .scan,
                                outputs: [N(symbol: "trash.fill", label: "Safe to clean", tint: .green), N(symbol: "hand.raised.fill", label: "Keep", tint: .orange)],
                                tokens: [T(symbol: "shippingbox.fill", tint: .green, output: 0), T(symbol: "doc.fill", tint: .orange, output: 1), T(symbol: "hammer.fill", tint: .green, output: 0), T(symbol: "photo.fill", tint: .orange, output: 1)])),
        ModuleInfo(key: "cleanup", title: "Cleanup", tagline: "Rebuildable build output and caches, sorted by impact.", symbol: "sparkles", tint: .green,
                   steps: ["Finds node_modules, build folders, caches and stale toolchains", "Recent projects stay; untouched ones are recommended", "Items go to the Trash, so you can put them back"],
                   scene: .init(source: N(symbol: "folder.fill", label: "Projects"), engine: N(symbol: "line.3.horizontal.decrease.circle.fill", label: "Rules", tint: .green), effect: .filter,
                                outputs: [N(symbol: "trash.fill", label: "Trash", tint: .green), N(symbol: "checkmark.circle.fill", label: "Active, keep", tint: .blue)],
                                tokens: [T(symbol: "shippingbox.fill", tint: .green, output: 0), T(symbol: "swift", tint: .blue, output: 1), T(symbol: "cube.fill", tint: .green, output: 0), T(symbol: "hammer.fill", tint: .green, output: 0)])),
        ModuleInfo(key: "explorer", title: "Disk Explorer", tagline: "See any folder as a map of what takes space.", symbol: "square.grid.3x3.square", tint: .purple,
                   steps: ["Pick a disk or folder", "Bigger tiles mean bigger folders", "Click to drill down; reveal or trash from there"],
                   scene: .init(source: N(symbol: "externaldrive.fill", label: "Folder"), engine: N(symbol: "square.grid.3x3.fill", label: "Measure", tint: .purple), effect: .pulse,
                                outputs: [N(symbol: "square.fill", label: "Big", tint: .purple), N(symbol: "square.grid.2x2.fill", label: "Small", tint: .secondary)],
                                tokens: [T(symbol: "film.fill", tint: .purple, output: 0), T(symbol: "doc.fill", tint: .secondary, output: 1), T(symbol: "archivebox.fill", tint: .purple, output: 0)])),
        ModuleInfo(key: "systemData", title: "System Data", tagline: "What \u{201C}System Data\u{201D} really is, and the parts you can shrink.", symbol: "internaldrive", tint: .indigo,
                   steps: ["Breaks System Data into snapshots, swap, caches and app data", "Explains which parts macOS manages itself", "Points to the safe levers for the rest"],
                   scene: .init(source: N(symbol: "internaldrive.fill", label: "System Data"), engine: N(symbol: "chart.bar.fill", label: "Break down", tint: .indigo), effect: .scan,
                                outputs: [N(symbol: "slider.horizontal.3", label: "You can shrink", tint: .green), N(symbol: "lock.fill", label: "macOS manages", tint: .secondary)],
                                tokens: [T(symbol: "clock.arrow.2.circlepath", tint: .green, output: 0), T(symbol: "memorychip.fill", tint: .secondary, output: 1), T(symbol: "tray.full.fill", tint: .green, output: 0)])),
        ModuleInfo(key: "offload", title: "Offload to Drive", tagline: "Move projects and folders to an external disk, verified.", symbol: "externaldrive.badge.plus", tint: .teal,
                   steps: ["Skips rebuildable caches, so less to copy", "Copies, then verifies every file with checksums", "Leaves a link behind, so paths keep working. Bring it back anytime"],
                   scene: .init(source: N(symbol: "laptopcomputer", label: "This Mac"), engine: N(symbol: "checkmark.shield.fill", label: "Copy + verify", tint: .teal), effect: .sync,
                                outputs: [N(symbol: "externaldrive.fill", label: "External SSD", tint: .teal), N(symbol: "xmark.bin.fill", label: "Skipped caches", tint: .secondary)],
                                tokens: [T(symbol: "folder.fill", tint: .teal, output: 0), T(symbol: "shippingbox.fill", tint: .secondary, output: 1), T(symbol: "doc.richtext.fill", tint: .teal, output: 0)])),
        ModuleInfo(key: "security", title: "Security", tagline: "Background items, packages and AI tools checked for malware patterns.", symbol: "shield.lefthalf.filled", tint: .red,
                   steps: ["Reads launch agents, npm/pip packages, AI skills and MCP configs", "Scores red flags: hidden payloads, credential theft, persistence", "Quarantine, restorable, with one click"],
                   scene: .init(source: N(symbol: "gearshape.2.fill", label: "Startup items"), engine: N(symbol: "shield.lefthalf.filled", label: "Inspect", tint: .red), effect: .shield,
                                outputs: [N(symbol: "checkmark.seal.fill", label: "Trusted", tint: .green), N(symbol: "lock.doc.fill", label: "Quarantine", tint: .red)],
                                tokens: [T(symbol: "terminal.fill", tint: .green, output: 0), T(symbol: "ladybug.fill", tint: .red, output: 1), T(symbol: "app.fill", tint: .green, output: 0)])),
        ModuleInfo(key: "codeBackup", title: "Code Backup", tagline: "Which projects exist only on this Mac.", symbol: "externaldrive.badge.checkmark", tint: .orange,
                   steps: ["Checks every project for git, remotes and unpushed work", "Flags code that would be lost with this disk", "Initialize, commit or push in place"],
                   scene: .init(source: N(symbol: "laptopcomputer", label: "Local code"), engine: N(symbol: "arrow.triangle.branch", label: "git status", tint: .orange), effect: .sync,
                                outputs: [N(symbol: "icloud.fill", label: "On a remote", tint: .green), N(symbol: "exclamationmark.triangle.fill", label: "Only here", tint: .orange)],
                                tokens: [T(symbol: "chevron.left.forwardslash.chevron.right", tint: .green, output: 0), T(symbol: "doc.text.fill", tint: .orange, output: 1), T(symbol: "circle.fill", tint: .green, output: 0)])),
        ModuleInfo(key: "secrets", title: "Secrets", tagline: "API keys, .env files and passwords where they shouldn't be.", symbol: "key.fill", tint: .yellow,
                   steps: ["Matches 35+ key formats and scores random-looking values", "Checks git: tracked, ignored, or already pushed", "Ignore, untrack, or lock down. Values are never shown"],
                   scene: .init(source: N(symbol: "doc.text.fill", label: ".env & code"), engine: N(symbol: "key.viewfinder", label: "Detect", tint: .yellow), effect: .scan,
                                outputs: [N(symbol: "lock.fill", label: "Ignored, local", tint: .green), N(symbol: "exclamationmark.icloud.fill", label: "Pushed: rotate", tint: .red)],
                                tokens: [T(symbol: "key.fill", tint: .green, output: 0), T(symbol: "key.fill", tint: .red, output: 1), T(symbol: "key.fill", tint: .green, output: 0)])),
        ModuleInfo(key: "doctor", title: "Project Doctor", tagline: "What broke when projects moved between disks.", symbol: "stethoscope", tint: .pink,
                   steps: ["Finds virtualenvs, worktrees and links pointing to old locations", "Spots stale git locks and bloated repositories", "Reconnects, relinks or optimizes, one fix at a time"],
                   scene: .init(source: N(symbol: "folder.fill.badge.questionmark", label: "Moved projects"), engine: N(symbol: "stethoscope", label: "Diagnose", tint: .pink), effect: .pulse,
                                outputs: [N(symbol: "link", label: "Relinked", tint: .green), N(symbol: "wand.and.stars", label: "Optimized", tint: .blue)],
                                tokens: [T(symbol: "link.badge.plus", tint: .green, output: 0), T(symbol: "archivebox.fill", tint: .blue, output: 1), T(symbol: "arrow.triangle.branch", tint: .green, output: 0)])),
        ModuleInfo(key: "taskManager", title: "Task Manager", tagline: "What's running, who started it, and whether it should.", symbol: "cpu", tint: .blue,
                   steps: ["Groups processes by app, with CPU and memory", "Traces each back to its launch item", "Quit, stop for good, or reveal"],
                   scene: .init(source: N(symbol: "cpu.fill", label: "Processes"), engine: N(symbol: "list.bullet.rectangle.fill", label: "Trace", tint: .blue), effect: .pulse,
                                outputs: [N(symbol: "play.fill", label: "Keep running", tint: .green), N(symbol: "stop.fill", label: "Stop", tint: .red)],
                                tokens: [T(symbol: "app.fill", tint: .green, output: 0), T(symbol: "flame.fill", tint: .red, output: 1), T(symbol: "terminal.fill", tint: .green, output: 0)])),
        ModuleInfo(key: "network", title: "Network", tagline: "Which app talks to whom, in plain language.", symbol: "network", tint: .cyan,
                   steps: ["Samples live connections per app", "Names services and spots regular beaconing", "Stop what you don't recognize"],
                   scene: .init(source: N(symbol: "app.connected.to.app.below.fill", label: "Apps"), engine: N(symbol: "dot.radiowaves.left.and.right", label: "Watch", tint: .cyan), effect: .sync,
                                outputs: [N(symbol: "globe", label: "Known services", tint: .green), N(symbol: "questionmark.diamond.fill", label: "Suspicious", tint: .orange)],
                                tokens: [T(symbol: "circle.fill", tint: .green, output: 0), T(symbol: "circle.fill", tint: .orange, output: 1), T(symbol: "circle.fill", tint: .green, output: 0), T(symbol: "circle.fill", tint: .green, output: 0)])),
        ModuleInfo(key: "apps", title: "Apps & Extensions", tagline: "Apps, their helpers, and add-ons left behind.", symbol: "square.grid.3x3.topleft.filled", tint: .mint,
                   steps: ["Maps each app to its agents, extensions and data", "Finds drivers and plug-ins whose app is gone", "Remove, disable, or move apps to another drive"],
                   scene: .init(source: N(symbol: "app.badge.fill", label: "Apps"), engine: N(symbol: "puzzlepiece.extension.fill", label: "Map parts", tint: .mint), effect: .scan,
                                outputs: [N(symbol: "checkmark.circle.fill", label: "Owned", tint: .green), N(symbol: "puzzlepiece.fill", label: "Dangling", tint: .orange)],
                                tokens: [T(symbol: "puzzlepiece.extension.fill", tint: .green, output: 0), T(symbol: "puzzlepiece.extension.fill", tint: .orange, output: 1), T(symbol: "gearshape.fill", tint: .green, output: 0)])),
        ModuleInfo(key: "duplicates", title: "Duplicate Finder", tagline: "Identical files, proven byte-for-byte.", symbol: "doc.on.doc", tint: .brown,
                   steps: ["Groups by size, then samples, then full hashes", "Hard links and symlinks never count as copies", "Keep one, trash the rest"],
                   scene: .init(source: N(symbol: "doc.on.doc.fill", label: "Files"), engine: N(symbol: "number.square.fill", label: "Hash", tint: .brown), effect: .filter,
                                outputs: [N(symbol: "doc.fill", label: "Keep one", tint: .green), N(symbol: "trash.fill", label: "Copies", tint: .secondary)],
                                tokens: [T(symbol: "doc.fill", tint: .green, output: 0), T(symbol: "doc.fill", tint: .secondary, output: 1), T(symbol: "doc.fill", tint: .secondary, output: 1)])),
        ModuleInfo(key: "maintenance", title: "Maintenance", tagline: "One-click fixes for common macOS glitches.", symbol: "wrench.and.screwdriver", tint: .gray,
                   steps: ["Each task says what it does and when to use it", "Admin tasks ask for your password", "Everything is logged in History"],
                   scene: .init(source: N(symbol: "desktopcomputer", label: "macOS"), engine: N(symbol: "wrench.and.screwdriver.fill", label: "Tune", tint: .gray), effect: .pulse,
                                outputs: [N(symbol: "bolt.fill", label: "Fixed", tint: .green), N(symbol: "arrow.down.circle.fill", label: "Space freed", tint: .blue)],
                                tokens: [T(symbol: "network", tint: .green, output: 0), T(symbol: "clock.arrow.2.circlepath", tint: .blue, output: 1), T(symbol: "eye.fill", tint: .green, output: 0)])),
        ModuleInfo(key: "timeline", title: "Space Timeline", tagline: "How free space changes, and when you'll run out.", symbol: "chart.xyaxis.line", tint: .accentColor,
                   steps: ["Prune samples free space on every disk while it runs", "Shows the trend and cleanups on one chart", "Forecasts the day the disk fills up"],
                   scene: .init(source: N(symbol: "internaldrive.fill", label: "Disks"), engine: N(symbol: "chart.xyaxis.line", label: "Trend", tint: .accentColor), effect: .pulse,
                                outputs: [N(symbol: "calendar", label: "Forecast", tint: .orange), N(symbol: "bell.fill", label: "Alerts", tint: .accentColor)],
                                tokens: [T(symbol: "circle.fill", tint: .accentColor, output: 0), T(symbol: "circle.fill", tint: .orange, output: 0), T(symbol: "circle.fill", tint: .accentColor, output: 1)])),
        ModuleInfo(key: "watched", title: "Watched Folders", tagline: "Get told when a folder suddenly grows.", symbol: "eye", tint: .accentColor,
                   steps: ["Pick folders that tend to balloon", "Prune checks their size in the background", "A notification when growth passes your threshold"],
                   scene: .init(source: N(symbol: "folder.fill", label: "Folder"), engine: N(symbol: "eye.fill", label: "Watch", tint: .accentColor), effect: .scan,
                                outputs: [N(symbol: "bell.badge.fill", label: "Grew", tint: .orange), N(symbol: "checkmark", label: "Stable", tint: .green)],
                                tokens: [T(symbol: "arrow.up", tint: .orange, output: 0), T(symbol: "equal", tint: .green, output: 1)])),
        ModuleInfo(key: "history", title: "History", tagline: "Everything Prune changed, with where to undo it.", symbol: "clock.arrow.circlepath", tint: .secondary,
                   steps: ["Every cleanup, move and fix is logged locally", "See what went to the Trash and how much it freed", "Nothing is uploaded"],
                   scene: .init(source: N(symbol: "hand.tap.fill", label: "Actions"), engine: N(symbol: "list.clipboard.fill", label: "Log", tint: .secondary), effect: .pulse,
                                outputs: [N(symbol: "clock.fill", label: "History", tint: .accentColor)],
                                tokens: [T(symbol: "trash.fill", tint: .accentColor, output: 0), T(symbol: "arrow.right.circle.fill", tint: .accentColor, output: 0)])),
    ]
}

// MARK: - Animated stage

struct ExplainerStage: View {
    let scene: ExplainerScene
    var tint: Color = .accentColor
    var height: CGFloat = 132
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { ctx in
            let t = reduceMotion ? 1.3 : ctx.date.timeIntervalSinceReferenceDate
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                let src = CGPoint(x: w * 0.12, y: h / 2), eng = CGPoint(x: w * 0.5, y: h / 2)
                let outs = scene.outputs.indices.map { i in
                    CGPoint(x: w * 0.88, y: scene.outputs.count == 1 ? h / 2 : h * (0.22 + 0.56 * Double(i) / Double(scene.outputs.count - 1)))
                }
                ZStack {
                    // Rails
                    Path { p in
                        p.move(to: src); p.addLine(to: eng)
                        for o in outs { p.move(to: eng); p.addCurve(to: o, control1: CGPoint(x: (eng.x + o.x) / 2, y: eng.y), control2: CGPoint(x: (eng.x + o.x) / 2, y: o.y)) }
                    }
                    .stroke(Color.secondary.opacity(0.28), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [4, 5], dashPhase: CGFloat(-t * 18)))

                    node(scene.source, at: src, size: 46)
                    engine(at: eng, t: t)
                    ForEach(scene.outputs.indices, id: \.self) { i in node(scene.outputs[i], at: outs[i], size: 40) }

                    ForEach(scene.tokens.indices, id: \.self) { i in
                        let tok = scene.tokens[i]
                        let cycle = 3.6, phase = (t / cycle + Double(i) / Double(scene.tokens.count)).truncatingRemainder(dividingBy: 1)
                        let o = outs[min(tok.output, outs.count - 1)]
                        let (pt, scale, opacity) = position(phase, src: src, eng: eng, out: o)
                        Image(systemName: tok.symbol)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 22, height: 22)
                            .background(RoundedRectangle(cornerRadius: 6).fill(phase < 0.45 ? Color.gray.opacity(0.75) : tok.tint))
                            .shadow(color: (phase < 0.45 ? .clear : tok.tint).opacity(0.5), radius: 4)
                            .scaleEffect(scale).opacity(opacity)
                            .position(pt)
                    }
                }
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }

    private func position(_ p: Double, src: CGPoint, eng: CGPoint, out: CGPoint) -> (CGPoint, CGFloat, Double) {
        func ease(_ x: Double) -> Double { x < 0.5 ? 2 * x * x : 1 - pow(-2 * x + 2, 2) / 2 }
        if p < 0.4 {
            let e = ease(p / 0.4)
            return (CGPoint(x: src.x + (eng.x - src.x) * e, y: src.y), 1, min(1, p / 0.06))
        } else if p < 0.52 {
            return (eng, 1 + 0.25 * sin((p - 0.4) / 0.12 * .pi), 1)
        } else {
            let e = ease((p - 0.52) / 0.48)
            // Same cubic as the rail.
            let c1 = CGPoint(x: (eng.x + out.x) / 2, y: eng.y), c2 = CGPoint(x: (eng.x + out.x) / 2, y: out.y)
            let u = 1 - e
            let x = u * u * u * eng.x + 3 * u * u * e * c1.x + 3 * u * e * e * c2.x + e * e * e * out.x
            let y = u * u * u * eng.y + 3 * u * u * e * c1.y + 3 * u * e * e * c2.y + e * e * e * out.y
            return (CGPoint(x: x, y: y), e > 0.9 ? 1 - (e - 0.9) * 4 : 1, e > 0.92 ? max(0, 1 - (e - 0.92) / 0.08) : 1)
        }
    }

    private func node(_ n: ExplainerScene.Node, at p: CGPoint, size: CGFloat) -> some View {
        VStack(spacing: 4) {
            Image(systemName: n.symbol)
                .font(.system(size: size * 0.42, weight: .medium))
                .foregroundStyle(n.tint == .secondary ? Color.primary.opacity(0.7) : n.tint)
                .frame(width: size, height: size)
                .background(RoundedRectangle(cornerRadius: size * 0.28).fill(.background))
                .overlay(RoundedRectangle(cornerRadius: size * 0.28).strokeBorder((n.tint == .secondary ? Color.secondary : n.tint).opacity(0.35)))
            Text(n.label).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary).fixedSize()
        }
        .position(x: p.x, y: p.y + 8)
    }

    private func engine(at p: CGPoint, t: Double) -> some View {
        let tint = scene.engine.tint
        return ZStack {
            Circle().fill(tint.opacity(0.10)).frame(width: 74, height: 74)
                .scaleEffect(1 + 0.06 * sin(t * 2.4))
            switch scene.effect {
            case .scan:
                Circle().trim(from: 0, to: 0.22).stroke(tint.opacity(0.8), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .frame(width: 66, height: 66).rotationEffect(.radians(t * 3))
            case .shield:
                Circle().stroke(tint.opacity(0.5 - 0.5 * (t * 0.8).truncatingRemainder(dividingBy: 1)), lineWidth: 2)
                    .frame(width: 56, height: 56).scaleEffect(1 + 0.4 * (t * 0.8).truncatingRemainder(dividingBy: 1))
            case .filter:
                ForEach(0..<3) { i in
                    Capsule().fill(tint.opacity(0.55)).frame(width: 30 - CGFloat(i) * 8, height: 3)
                        .offset(y: CGFloat(i) * 7 - 7 + CGFloat(sin(t * 3 + Double(i))) * 1.5)
                        .offset(y: 28)
                }
            case .sync:
                Circle().trim(from: 0, to: 0.4).stroke(tint.opacity(0.7), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .frame(width: 64, height: 64).rotationEffect(.radians(-t * 2))
                Circle().trim(from: 0.5, to: 0.9).stroke(tint.opacity(0.4), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .frame(width: 64, height: 64).rotationEffect(.radians(-t * 2))
            case .pulse:
                Circle().stroke(tint.opacity(0.25), lineWidth: 2).frame(width: 64, height: 64)
                    .scaleEffect(1 + 0.08 * sin(t * 4))
            }
            Image(systemName: scene.engine.symbol).font(.system(size: 22, weight: .semibold)).foregroundStyle(tint)
                .frame(width: 50, height: 50).background(Circle().fill(.background))
                .overlay(Circle().strokeBorder(tint.opacity(0.5), lineWidth: 1.5))
            Text(scene.engine.label).font(.system(size: 10, weight: .semibold)).foregroundStyle(tint).offset(y: 44)
        }
        .position(p)
    }
}

/// The step captions advance in step with the animation.
struct ExplainerSteps: View {
    let steps: [String]
    let tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.periodic(from: .now, by: 2.4)) { ctx in
            let active = reduceMotion ? -1 : Int(ctx.date.timeIntervalSinceReferenceDate / 2.4) % max(steps.count, 1)
            VStack(alignment: .leading, spacing: 7) {
                ForEach(steps.indices, id: \.self) { i in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(i + 1)").font(.caption2.weight(.bold).monospacedDigit())
                            .foregroundStyle(i == active ? .white : tint)
                            .frame(width: 18, height: 18)
                            .background(Circle().fill(i == active ? tint : tint.opacity(0.14)))
                        Text(steps[i]).font(.callout).foregroundStyle(i == active ? .primary : .secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .animation(.snappy, value: active)
                }
            }
        }
    }
}

/// Collapsible "How it works" card shown at the top of a module the first time it's opened.
struct ModuleIntroCard: View {
    let route: Route
    @State private var guide = ModuleGuide.shared

    var body: some View {
        let info = ModuleGuide.info(route.guideKey)
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: info.symbol).foregroundStyle(info.tint)
                    Text("How \(info.title) works").font(.headline)
                }
                Text(info.tagline).font(.callout).foregroundStyle(.secondary)
                ExplainerSteps(steps: info.steps, tint: info.tint)
            }
            .frame(maxWidth: 360, alignment: .leading)
            ExplainerStage(scene: info.scene, tint: info.tint)
                .frame(maxWidth: .infinity)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(.background.secondary))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(info.tint.opacity(0.25)))
        .overlay(alignment: .topTrailing) {
            Button { guide.dismiss(route) } label: { Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.tertiary) }
                .buttonStyle(.plain).padding(8).help("Hide (bring it back with How it works in the toolbar)")
        }
        .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 4)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

// MARK: - Welcome tour

struct WelcomeTour: View {
    @State private var page = 0
    @State private var guide = ModuleGuide.shared
    private let keys = ["overview", "cleanup", "offload", "secrets", "codeBackup", "security", "doctor"]

    var body: some View {
        let info = ModuleGuide.info(keys[page])
        VStack(spacing: 18) {
            HStack {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 34, height: 34)
                Text("Welcome to Prune").font(.title2.weight(.bold))
                Spacer()
                Text("\(page + 1) of \(keys.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            VStack(spacing: 14) {
                HStack(spacing: 8) {
                    Image(systemName: info.symbol).font(.title2).foregroundStyle(info.tint)
                        .symbolEffect(.bounce, value: page)
                    Text(info.title).font(.title3.weight(.semibold))
                }
                Text(info.tagline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                ExplainerStage(scene: info.scene, tint: info.tint, height: 170)
                    .padding(.horizontal, 10)
                    .background(RoundedRectangle(cornerRadius: 16).fill(.background.secondary))
                ExplainerSteps(steps: info.steps, tint: info.tint).frame(maxWidth: .infinity, alignment: .leading)
            }
            .id(page)
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .move(edge: .leading).combined(with: .opacity)))
            HStack(spacing: 6) {
                ForEach(keys.indices, id: \.self) { i in
                    Capsule().fill(i == page ? Color.accentColor : Color.secondary.opacity(0.3)).frame(width: i == page ? 18 : 6, height: 6)
                }
            }
            .animation(.snappy, value: page)
            HStack {
                Button("Skip") { guide.finishTour() }.buttonStyle(.borderless)
                Spacer()
                if page > 0 { Button("Back") { withAnimation(.snappy) { page -= 1 } } }
                Button(page == keys.count - 1 ? "Start using Prune" : "Next") {
                    if page == keys.count - 1 { guide.finishTour() } else { withAnimation(.snappy) { page += 1 } }
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 620)
    }
}
