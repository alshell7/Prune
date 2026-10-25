import Foundation

/// How much it costs you if an item is removed.
enum Risk: Int, Codable, CaseIterable, Comparable, Identifiable {
    case safe = 0, low, review, high

    static func < (a: Risk, b: Risk) -> Bool { a.rawValue < b.rawValue }
    var id: Int { rawValue }

    var label: String {
        switch self {
        case .safe: "Safe"
        case .low: "Low risk"
        case .review: "Review"
        case .high: "High risk"
        }
    }

    var blurb: String {
        switch self {
        case .safe: "Regenerated automatically. No data loss."
        case .low: "Rebuilt or re-downloaded on demand. Costs time or bandwidth."
        case .review: "May hold data or state you care about. Check before removing."
        case .high: "Hard to recover. Remove only if you are certain."
        }
    }
}

/// Prune's verdict for an item.
enum Recommendation: Int, Codable, Comparable {
    case recommended = 0, optional, keep

    static func < (a: Recommendation, b: Recommendation) -> Bool { a.rawValue < b.rawValue }

    var label: String {
        switch self {
        case .recommended: "Recommended"
        case .optional: "Optional"
        case .keep: "Keep"
        }
    }
}

enum Category: String, CaseIterable, Identifiable, Codable {
    case projectArtifacts, environments, devCaches, xcode, worktrees, docker, editors, aiModels, systemJunk, applications, dangling, largeFiles

    var id: String { rawValue }

    var title: String {
        switch self {
        case .projectArtifacts: "Project Artifacts"
        case .environments: "Dev Environments"
        case .devCaches: "Developer Caches"
        case .xcode: "Xcode & Simulators"
        case .worktrees: "Git Worktrees"
        case .docker: "Docker & Homebrew"
        case .editors: "Editors & IDEs"
        case .aiModels: "AI Models & Tools"
        case .systemJunk: "System Junk"
        case .applications: "Applications"
        case .dangling: "Dangling & Orphaned"
        case .largeFiles: "Large & Old Files"
        }
    }

    var icon: String {
        switch self {
        case .projectArtifacts: "shippingbox"
        case .environments: "cpu"
        case .devCaches: "archivebox"
        case .xcode: "hammer"
        case .worktrees: "arrow.triangle.branch"
        case .docker: "cube.transparent"
        case .editors: "chevron.left.forwardslash.chevron.right"
        case .aiModels: "brain"
        case .systemJunk: "trash"
        case .applications: "app.dashed"
        case .dangling: "link.badge.plus"
        case .largeFiles: "doc.richtext"
        }
    }

    var blurb: String {
        switch self {
        case .projectArtifacts: "node_modules, build outputs, virtualenvs and compiler caches inside your projects. Prune checks each one against its project's manifest and git status, and judges it by how recently the project was active."
        case .environments: "SDKs, toolchains and runtimes (Android SDK, NDK, Gradle, Rust, Go, Node, Python, JDKs, simulator runtimes). Each version is cross-referenced against what your projects actually pin."
        case .devCaches: "Package-manager and build-tool caches. They are re-downloaded on demand. Prune weighs them against how active each ecosystem is."
        case .xcode: "DerivedData, device support files, simulator runtimes and archives."
        case .worktrees: "Linked git worktrees. A clean worktree can be removed without losing anything: its branch and commits stay in the repository."
        case .docker: "Docker images, build cache and volumes, plus Homebrew downloads and orphaned dependencies."
        case .editors: "VS Code-family extensions and workspace data, JetBrains caches from old IDE versions, Electron app caches."
        case .aiModels: "Local AI models (Hugging Face, Ollama, LM Studio, Chrome's on-device model) and AI tool data: Claude Desktop's sandbox VM and bundled Claude Code builds, Codex session history."
        case .systemJunk: "Application caches, logs, crash reports, updater leftovers, and the Trash."
        case .applications: "Apps you haven't opened in months, plus everything they leave behind in your Library."
        case .dangling: "Things pointing to nothing: data left by uninstalled apps, broken symlinks, launch agents for missing programs, broken worktree links."
        case .largeFiles: "Big files on all indexed volumes, plus old installers in Downloads."
        }
    }
}

struct ShellCommand: Hashable, Codable {
    var tool: String          // absolute path
    var args: [String]
    var cwd: String?
    var needsAdmin = false

    var display: String {
        ([URL(fileURLWithPath: tool).lastPathComponent] + args.map(Shell.quoteIfNeeded)).joined(separator: " ")
    }
}

enum CleanupAction: Hashable {
    case removeFiles          // Trash (or delete when safe + setting enabled)
    case uninstallApp         // NSWorkspace recycle for the bundle + leftovers
    case command(ShellCommand)
    case emptyTrash
    case none                 // informational only
}

struct CleanupItem: Identifiable, Hashable {
    var id: String
    var category: Category
    var title: String
    var subtitle: String
    var group: String?
    var paths: [URL]
    var size: Int64
    var risk: Risk
    var recommendation: Recommendation
    var reason: String
    var whatItIs: String
    var whyRemove: String?
    var whyKeep: String?
    var impact: String
    var restore: String?
    var lastUsed: Date?
    var action: CleanupAction
    var needsAdmin = false
    var lockedReason: String?
    var appBundleID: String?
    var usedBy: [String] = []
    var sizeIsEstimate = false

    init(id: String? = nil, category: Category, title: String, subtitle: String = "", group: String? = nil,
         paths: [URL], size: Int64, risk: Risk, recommendation: Recommendation, reason: String,
         whatItIs: String, whyRemove: String? = nil, whyKeep: String? = nil, impact: String,
         restore: String? = nil, lastUsed: Date? = nil, action: CleanupAction = .removeFiles,
         needsAdmin: Bool = false, lockedReason: String? = nil, appBundleID: String? = nil,
         usedBy: [String] = [], sizeIsEstimate: Bool = false) {
        self.id = id ?? "\(category.rawValue):\(paths.map(\.path).joined(separator: "|")):\(title)"
        self.category = category
        self.title = title
        self.subtitle = subtitle
        self.group = group
        self.paths = paths
        self.size = size
        self.risk = risk
        self.recommendation = recommendation
        self.reason = reason
        self.whatItIs = whatItIs
        self.whyRemove = whyRemove
        self.whyKeep = whyKeep
        self.impact = impact
        self.restore = restore
        self.lastUsed = lastUsed
        self.action = action
        self.needsAdmin = needsAdmin
        self.lockedReason = lockedReason
        self.appBundleID = appBundleID
        self.usedBy = usedBy
        self.sizeIsEstimate = sizeIsEstimate
    }

    var isActionable: Bool {
        if lockedReason != nil { return false }
        if case .none = action { return false }
        return true
    }

    /// Counted toward "reclaimable" totals.
    var countsAsReclaimable: Bool { isActionable && recommendation != .keep }

    // Sort keys for tables
    var lastUsedSort: Date { lastUsed ?? .distantPast }
    var riskSort: Int { risk.rawValue }
    var recommendationSort: Int { recommendation.rawValue }
    var groupSort: String { group ?? "" }

    var actionDescription: String {
        switch action {
        case .removeFiles: return needsAdmin ? "Move to Trash (administrator password required)" : "Move to Trash"
        case .uninstallApp: return "Move the app and its leftovers to Trash"
        case .command(let c): return "Run: \(c.display)"
        case .emptyTrash: return "Permanently erase everything in the Trash"
        case .none: return "Informational. Prune takes no action."
        }
    }
}

extension Array where Element == CleanupItem {
    var totalSize: Int64 { reduce(0) { $0 + $1.size } }
}
