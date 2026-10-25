import Foundation

struct EditorScanner: Scanner {
    let name = "Editors & IDEs"

    struct Editor { var name: String; var extDir: String; var support: String; var cli: [String]; var bundleID: String }

    static let editors: [Editor] = [
        Editor(name: "VS Code", extDir: "~/.vscode/extensions", support: "~/Library/Application Support/Code", cli: ["code"], bundleID: "com.microsoft.VSCode"),
        Editor(name: "VS Code Insiders", extDir: "~/.vscode-insiders/extensions", support: "~/Library/Application Support/Code - Insiders", cli: ["code-insiders"], bundleID: "com.microsoft.VSCodeInsiders"),
        Editor(name: "Cursor", extDir: "~/.cursor/extensions", support: "~/Library/Application Support/Cursor", cli: ["cursor"], bundleID: "com.todesktop.230313mzl4w4u92"),
        Editor(name: "Windsurf", extDir: "~/.windsurf/extensions", support: "~/Library/Application Support/Windsurf", cli: ["windsurf"], bundleID: "com.exafunction.windsurf"),
        Editor(name: "VSCodium", extDir: "~/.vscode-oss/extensions", support: "~/Library/Application Support/VSCodium", cli: ["codium"], bundleID: "com.vscodium"),
        Editor(name: "Antigravity", extDir: "~/.antigravity/extensions", support: "~/Library/Application Support/Antigravity", cli: ["antigravity"], bundleID: "com.google.antigravity"),
        Editor(name: "Kiro", extDir: "~/.kiro/extensions", support: "~/Library/Application Support/Kiro", cli: ["kiro"], bundleID: "dev.kiro.desktop"),
        Editor(name: "Trae", extDir: "~/.trae/extensions", support: "~/Library/Application Support/Trae", cli: ["trae"], bundleID: "com.trae.app"),
    ]

    func scan(_ ctx: ScanContext, _ progress: ScanProgress) -> [CleanupItem] {
        var items: [CleanupItem] = []
        for ed in Self.editors {
            progress.update("Checking \(ed.name)…")
            items += extensions(ctx, ed)
            items += workspaceStorage(ctx, ed)
            items += cachedData(ctx, ed)
        }
        progress.update("Checking JetBrains IDEs…")
        items += jetbrains(ctx)
        return items
    }

    private func extensions(_ ctx: ScanContext, _ ed: Editor) -> [CleanupItem] {
        let dir = ctx.url(ed.extDir)
        guard FS.isDir(dir) else { return [] }
        var items: [CleanupItem] = []
        let folders = FS.childDirs(dir).filter { !$0.lastPathComponent.hasPrefix(".") }
        var referenced = Set<String>()
        var hasRegistry = false
        if let arr = FS.readJSON(dir.appendingPathComponent("extensions.json")) as? [[String: Any]] {
            hasRegistry = true
            for e in arr {
                if let rel = e["relativeLocation"] as? String { referenced.insert(rel) }
                if let loc = e["location"] as? [String: Any], let p = (loc["path"] as? String) ?? (loc["fsPath"] as? String) {
                    referenced.insert((p as NSString).lastPathComponent)
                }
            }
        }
        let obsoleteMarked = Set((FS.readJSON(dir.appendingPathComponent(".obsolete")) as? [String: Any])?.keys.map { $0 } ?? [])

        // Group by extension id to find superseded versions even without a registry.
        func split(_ name: String) -> (id: String, version: String)? {
            guard let r = name.range(of: #"-\d+\.\d+\.\d+"#, options: .regularExpression) else { return nil }
            return (String(name[..<r.lowerBound]), String(name[name.index(after: r.lowerBound)...]))
        }
        var byID: [String: [URL]] = [:]
        for f in folders { if let s = split(f.lastPathComponent) { byID[s.id, default: []].append(f) } }
        var obsolete: [URL] = []
        for f in folders {
            let n = f.lastPathComponent
            if obsoleteMarked.contains(n) { obsolete.append(f); continue }
            if hasRegistry && !referenced.isEmpty && !referenced.contains(n) { obsolete.append(f); continue }
            if !hasRegistry, let s = split(n), let siblings = byID[s.id], siblings.count > 1,
               let newest = siblings.max(by: { Versions.compare(split($0.lastPathComponent)!.version, split($1.lastPathComponent)!.version) }), newest != f {
                obsolete.append(f)
            }
        }
        let sizes = Sizer.measureMany(folders)
        if !obsolete.isEmpty {
            let total = obsolete.reduce(Int64(0)) { $0 + (sizes[$1]?.bytes ?? 0) }
            if total >= ctx.minBytes {
                items.append(CleanupItem(
                    category: .editors, title: "\(ed.name) · superseded extension versions", subtitle: "\(obsolete.count) folders", group: ed.name,
                    paths: obsolete, size: total, risk: .safe, recommendation: .recommended,
                    reason: "Old versions left behind after extension updates or uninstalls.",
                    whatItIs: "Extension folders \(ed.name) no longer loads: \(obsolete.prefix(5).map(\.lastPathComponent).joined(separator: ", "))\(obsolete.count > 5 ? "…" : "").",
                    whyRemove: "\(ed.name) marks them obsolete or no longer lists them in its extension registry.",
                    impact: "None. The active versions are untouched.", restore: nil, appBundleID: ed.bundleID))
            }
        }
        // Large active extensions, uninstalled via the editor's CLI so its registry stays consistent.
        let cli = ed.cli.lazy.compactMap { Shell.which($0) }.first
        for f in folders where !obsolete.contains(f) {
            guard let m = sizes[f], m.bytes >= 150 * 1_048_576, let s = split(f.lastPathComponent) else { continue }
            items.append(CleanupItem(
                category: .editors, title: "\(ed.name) · \(s.id)", subtitle: "Extension v\(s.version)", group: ed.name,
                paths: [f], size: m.bytes, risk: .low, recommendation: .optional,
                reason: "Large extension (\(Fmt.bytes(m.bytes))).",
                whatItIs: "An installed \(ed.name) extension. Language servers and AI assistants often bundle large binaries.",
                whyKeep: "If you use it, uninstalling just means reinstalling later from the marketplace.",
                impact: "The extension is uninstalled from \(ed.name).", restore: "\(ed.cli.first ?? "code") --install-extension \(s.id)",
                lastUsed: m.newest,
                action: cli.map { .command(ShellCommand(tool: $0, args: ["--uninstall-extension", s.id])) } ?? .none,
                lockedReason: cli == nil ? "The \(ed.cli.first ?? "") command isn't on PATH. Uninstall from inside \(ed.name)." : nil,
                appBundleID: ed.bundleID))
        }
        return items
    }

    private func workspaceStorage(_ ctx: ScanContext, _ ed: Editor) -> [CleanupItem] {
        let ws = ctx.url(ed.support).appendingPathComponent("User/workspaceStorage")
        let dirs = FS.childDirs(ws)
        guard !dirs.isEmpty else { return [] }
        var orphans: [URL] = []
        var stale: [URL] = []
        for d in dirs {
            guard let json = FS.readJSON(d.appendingPathComponent("workspace.json")) as? [String: Any] else { continue }
            guard let uri = (json["folder"] as? String) ?? (json["workspace"] as? String), uri.hasPrefix("file://"),
                  let url = URL(string: uri), url.isFileURL else { continue }
            if !FS.exists(url) { orphans.append(d) }
            else if (Age.days(FS.mtime(d)) ?? 0) > 180 { stale.append(d) }
        }
        var items: [CleanupItem] = []
        let sizes = Sizer.measureMany(orphans + stale)
        let oTotal = orphans.reduce(Int64(0)) { $0 + (sizes[$1]?.bytes ?? 0) }
        if !orphans.isEmpty && oTotal >= 512 * 1024 {
            items.append(CleanupItem(
                category: .dangling, title: "\(ed.name) · data for deleted folders", subtitle: "\(orphans.count) workspaces", group: ed.name,
                paths: orphans, size: oTotal, risk: .safe, recommendation: .recommended,
                reason: "These workspaces' folders no longer exist.",
                whatItIs: "Per-workspace state (local history, extension storage, AI/indexing caches) for folders that were deleted or moved.",
                whyRemove: "Nothing can open these workspaces again.",
                impact: "None for existing projects.", restore: nil, appBundleID: ed.bundleID))
        }
        let sTotal = stale.reduce(Int64(0)) { $0 + (sizes[$1]?.bytes ?? 0) }
        if !stale.isEmpty && sTotal >= ctx.minBytes {
            items.append(CleanupItem(
                category: .editors, title: "\(ed.name) · workspaces not opened in 6+ months", subtitle: "\(stale.count) workspaces", group: ed.name,
                paths: stale, size: sTotal, risk: .low, recommendation: .optional,
                reason: "Workspace state not touched in over six months.",
                whatItIs: "Per-workspace state: Local History snapshots, extension storage, search and AI indexes.",
                whyKeep: "Local History (unsaved file timelines) for those folders would be lost.",
                impact: "Opening those folders again starts with fresh workspace state.", restore: nil, appBundleID: ed.bundleID))
        }
        return items
    }

    private func cachedData(_ ctx: ScanContext, _ ed: Editor) -> [CleanupItem] {
        let support = ctx.url(ed.support)
        var items: [CleanupItem] = []
        let cd = FS.childDirs(support.appendingPathComponent("CachedData"))
        if cd.count > 1 {
            let newest = cd.max { (FS.mtime($0) ?? .distantPast) < (FS.mtime($1) ?? .distantPast) }
            let old = cd.filter { $0 != newest }
            let total = Sizer.measureMany(old).values.reduce(0) { $0 + $1.bytes }
            if total >= ctx.minBytes {
                items.append(CleanupItem(
                    category: .editors, title: "\(ed.name) · old version caches", subtitle: "\(old.count) previous builds", group: ed.name,
                    paths: old, size: total, risk: .safe, recommendation: .recommended, reason: "Left over from previous \(ed.name) updates.",
                    whatItIs: "V8 code caches for \(ed.name) versions you no longer run.", impact: "None.", restore: nil, appBundleID: ed.bundleID))
            }
        }
        for (rel, title) in [("CachedExtensionVSIXs", "downloaded extension packages"), ("logs", "logs"), ("CachedProfilesData", "profile caches")] {
            if let i = ctx.cacheItem(.editors, path: support.appendingPathComponent(rel).path, title: "\(ed.name) · \(title)", subtitle: FS.tildePath(support.appendingPathComponent(rel)),
                                     risk: .safe, what: "\(ed.name) \(title). Recreated when needed.", impact: "None.", restore: "Automatic",
                                     appBundleID: ed.bundleID, group: ed.name) {
                items.append(i)
            }
        }
        return items
    }

    private func jetbrains(_ ctx: ScanContext) -> [CleanupItem] {
        let h = FS.home
        let roots: [(URL, String, Risk)] = [
            (h.appendingPathComponent("Library/Caches/JetBrains"), "caches & indexes", .safe),
            (h.appendingPathComponent("Library/Logs/JetBrains"), "logs", .safe),
            (h.appendingPathComponent("Library/Application Support/JetBrains"), "settings & plugins", .low),
            (h.appendingPathComponent("Library/Caches/Google"), "caches & indexes", .safe),
            (h.appendingPathComponent("Library/Logs/Google"), "logs", .safe),
            (h.appendingPathComponent("Library/Application Support/Google"), "settings & plugins", .low),
        ]
        // Product → [(version, folder, kind, risk)]
        var byProduct: [String: [(String, URL, String, Risk)]] = [:]
        for (root, kind, risk) in roots {
            for d in FS.childDirs(root) {
                guard let r = d.lastPathComponent.range(of: #"^([A-Za-z]+?)(\d{4}\.\d+)$"#, options: .regularExpression) else { continue }
                let name = String(d.lastPathComponent[r])
                guard let vr = name.range(of: #"\d{4}\.\d+$"#, options: .regularExpression) else { continue }
                let product = String(name[..<vr.lowerBound]), version = String(name[vr])
                if root.path.contains("/Google"), !product.hasPrefix("AndroidStudio") { continue }
                byProduct[product, default: []].append((version, d, kind, risk))
            }
        }
        var items: [CleanupItem] = []
        for (product, entries) in byProduct {
            let newest = entries.map(\.0).max(by: Versions.compare) ?? ""
            for (version, dir, kind, risk) in entries {
                let isNewest = version == newest
                if isNewest && kind == "settings & plugins" { continue }
                guard var i = ctx.cacheItem(.editors, path: dir.path, title: "\(product) \(version) · \(kind)", subtitle: FS.tildePath(dir),
                                            risk: risk, what: isNewest ? "\(product)'s \(kind) for the version you run now." : "\(product) \(kind) from version \(version), superseded by \(newest).",
                                            impact: kind == "caches & indexes" ? "Projects are re-indexed on next open." : "Nothing. \(newest) already migrated what it needs.",
                                            restore: "Automatic", group: product) else { continue }
                if isNewest {
                    i.recommendation = kind == "logs" ? .recommended : .optional
                    i.reason = kind == "logs" ? "Log files." : "Current IDE version. Clearing it forces a full re-index."
                } else {
                    i.recommendation = .recommended
                    i.reason = "Left over from \(product) \(version). You now run \(newest)."
                    i.whyRemove = "When the IDE upgraded to \(newest), it copied your settings forward and stopped using this folder."
                }
                items.append(i)
            }
        }
        return items
    }
}

struct AIModelScanner: Scanner {
    let name = "AI models"

    func scan(_ ctx: ScanContext, _ progress: ScanProgress) -> [CleanupItem] {
        var items: [CleanupItem] = []
        let env = ProcessInfo.processInfo.environment
        let hfHome = env["HF_HOME"].map { URL(fileURLWithPath: $0) } ?? FS.home.appendingPathComponent(".cache/huggingface")
        progress.update("Looking for downloaded models…")

        let hub = hfHome.appendingPathComponent("hub")
        let repos = FS.childDirs(hub).filter { $0.lastPathComponent.hasPrefix("models--") || $0.lastPathComponent.hasPrefix("datasets--") }
        // Files inside a repo may be symlinks into a shared store (e.g. hub/blobs/xx/<hash>).
        // Attribute each target to the repos that reference it, so sizes and removals are complete.
        var targetsByRepo: [URL: Set<String>] = [:]
        var refCount: [String: Int] = [:]
        for r in repos {
            var targets = Set<String>()
            if let e = FileManager.default.enumerator(atPath: r.path) {
                while let rel = e.nextObject() as? String {
                    let p = r.appendingPathComponent(rel)
                    guard FS.isSymlink(p) else { continue }
                    let t = p.resolvingSymlinksInPath().path
                    if FS.isAncestor(hub.path, of: t), !FS.isAncestor(r.path, of: t), FS.exists(URL(fileURLWithPath: t)) { targets.insert(t) }
                }
            }
            targetsByRepo[r] = targets
            for t in targets { refCount[t, default: 0] += 1 }
        }
        let own = Sizer.measureMany(repos)
        for r in repos {
            let targets = targetsByRepo[r] ?? []
            let exclusive = targets.filter { refCount[$0] == 1 }.map { URL(fileURLWithPath: $0) }
            let linked = Sizer.measureMany(targets.map { URL(fileURLWithPath: $0) }).values.reduce(Int64(0)) { $0 + $1.bytes }
            let size = (own[r]?.bytes ?? 0) + linked
            guard size >= ctx.minBytes else { continue }
            let isDataset = r.lastPathComponent.hasPrefix("datasets--")
            let name = r.lastPathComponent.replacingOccurrences(of: isDataset ? "datasets--" : "models--", with: "").replacingOccurrences(of: "--", with: "/")
            var item = modelItem(ctx, title: name, subtitle: isDataset ? "Hugging Face dataset" : "Hugging Face model", group: "Hugging Face",
                                 url: r, size: size, date: own[r]?.newest,
                                 what: "Weights downloaded by transformers/diffusers/huggingface_hub (from_pretrained, snapshot_download).",
                                 restore: "Downloaded again automatically on next from_pretrained(\"\(name)\")")
            item.paths += exclusive
            items.append(item)
        }
        // Blobs in the shared store that no repo references anymore (aborted or replaced downloads).
        let sharedBlobs = hub.appendingPathComponent("blobs")
        if FS.isDir(sharedBlobs) {
            var unreferenced: [URL] = []
            if let e = FileManager.default.enumerator(atPath: sharedBlobs.path) {
                while let rel = e.nextObject() as? String {
                    let p = sharedBlobs.appendingPathComponent(rel)
                    if !FS.isDir(p), refCount[p.resolvingSymlinksInPath().path] == nil { unreferenced.append(p) }
                }
            }
            let total = Sizer.measureMany(unreferenced).values.reduce(Int64(0)) { $0 + $1.bytes }
            if total >= ctx.minBytes {
                items.append(CleanupItem(
                    category: .aiModels, title: "Unreferenced Hugging Face blobs", subtitle: "\(unreferenced.count) files", group: "Hugging Face",
                    paths: unreferenced, size: total, risk: .safe, recommendation: .recommended,
                    reason: "No downloaded model or dataset points to these files.",
                    whatItIs: "Pieces of downloads that were aborted or replaced by newer revisions.",
                    impact: "None. No model uses them.", restore: nil))
            }
        }
        for rel in ["xet", "datasets", "modules", "assets"] {
            if let i = ctx.cacheItem(.aiModels, path: hfHome.appendingPathComponent(rel).path, title: "Hugging Face \(rel) cache", subtitle: FS.tildePath(hfHome.appendingPathComponent(rel)),
                                     risk: .safe, what: "Auxiliary Hugging Face cache (chunk store, processed datasets, remote code).",
                                     impact: "Rebuilt on next download/load.", restore: "Automatic", group: "Hugging Face") { items.append(i) }
        }

        // Ollama
        if let ollama = Shell.which("ollama") {
            let r = Shell.run(ollama, ["list"], timeout: 10)
            if r.ok {
                for line in r.stdout.split(separator: "\n").dropFirst() {
                    let cols = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
                    guard cols.count >= 4 else { continue }
                    let size = DockerBrewScanner.parseSize(cols[2] + cols[3])
                    guard size >= ctx.minBytes else { continue }
                    let modified = cols.dropFirst(4).joined(separator: " ")
                    var item = modelItem(ctx, title: cols[0], subtitle: "Ollama model", group: "Ollama", url: FS.home.appendingPathComponent(".ollama/models/manifests"),
                                         size: size, date: nil, what: "A local LLM pulled with `ollama pull`.", restore: "ollama pull \(cols[0])")
                    item.id = "ollama:\(cols[0])"
                    item.paths = []
                    item.action = .command(ShellCommand(tool: ollama, args: ["rm", cols[0]]))
                    item.reason = "Last modified \(modified)."
                    items.append(item)
                }
            }
        } else if let i = ctx.cacheItem(.aiModels, path: "~/.ollama/models", title: "Ollama models", subtitle: "~/.ollama/models", risk: .low,
                                        what: "Models pulled with Ollama (the CLI isn't installed anymore).",
                                        impact: "Models would need pulling again.", restore: "ollama pull <model>", group: "Ollama") {
            var i = i; i.recommendation = .recommended; i.reason = "Ollama isn't installed, so nothing can use these."
            items.append(i)
        }

        // LM Studio
        for base in ["~/.lmstudio/models", "~/.cache/lm-studio/models"].map(ctx.url) {
            for pub in FS.childDirs(base) {
                for model in FS.childDirs(pub) {
                    let m = Sizer.measure(model)
                    guard m.bytes >= ctx.minBytes else { continue }
                    items.append(modelItem(ctx, title: "\(pub.lastPathComponent)/\(model.lastPathComponent)", subtitle: "LM Studio model", group: "LM Studio",
                                           url: model, size: m.bytes, date: m.newest, what: "A GGUF/MLX model downloaded in LM Studio.", restore: "Download again in LM Studio"))
                }
            }
        }

        // Chrome's on-device model (Gemini Nano)
        for (browser, path) in [("Chrome", "~/Library/Application Support/Google/Chrome/OptGuideOnDeviceModel"),
                                ("Chrome Canary", "~/Library/Application Support/Google/Chrome Canary/OptGuideOnDeviceModel"),
                                ("Edge", "~/Library/Application Support/Microsoft Edge/EdgeLLMOnDeviceModel")] {
            if let i = ctx.cacheItem(.aiModels, path: path, title: "\(browser) on-device AI model", subtitle: path, risk: .low,
                                     what: "\(browser)'s built-in Gemini Nano model, used for \u{201C}Help me write\u{201D}, summarization and the Prompt API.",
                                     impact: "\(browser) re-downloads it in the background when an AI feature needs it, unless you turn it off in chrome://flags (Optimization Guide On Device Model).",
                                     restore: "Automatic", whyKeep: "Built-in browser AI features stop working offline until it's re-downloaded.",
                                     group: "Browsers") {
                var i = i; i.recommendation = .optional; i.reason = "\(browser) will re-download it unless the feature is disabled."
                items.append(i)
            }
        }

        // Other common model caches
        for (path, title) in [("~/.cache/whisper", "Whisper models"), ("~/.cache/torch/hub", "PyTorch Hub checkpoints"), ("~/.keras/models", "Keras models"),
                              ("~/.cache/gpt4all", "GPT4All models"), ("~/.cache/llama.cpp", "llama.cpp downloads"),
                              ("~/Library/Application Support/nomic.ai/GPT4All", "GPT4All models"), ("~/.cache/lm-studio/extensions", "LM Studio runtimes")] {
            if let i = ctx.cacheItem(.aiModels, path: path, title: title, subtitle: path, risk: .low, what: "Model weights downloaded by \(title.components(separatedBy: " ").first ?? "a tool").",
                                     impact: "Re-downloaded on next use.", restore: "Automatic on next use", group: "Other") {
                var i = i; i.recommendation = (Age.days(i.lastUsed) ?? 999) >= ctx.staleDays * 2 ? .recommended : .optional
                i.reason = "Downloaded \(Fmt.ago(i.lastUsed))."
                items.append(i)
            }
        }
        return items
    }

    private func modelItem(_ ctx: ScanContext, title: String, subtitle: String, group: String, url: URL, size: Int64, date: Date?, what: String, restore: String) -> CleanupItem {
        let days = Age.days(date) ?? 999
        let stale = days >= ctx.staleDays * 3
        return CleanupItem(
            category: .aiModels, title: title, subtitle: subtitle, group: group, paths: [url], size: size, risk: .low,
            recommendation: stale ? .recommended : .optional,
            reason: date == nil ? "Downloaded model." : (stale ? "Downloaded \(Fmt.ago(date)) and not updated since." : "Downloaded \(Fmt.ago(date))."),
            whatItIs: what,
            whyKeep: "Re-downloading large models takes time and bandwidth. Keep the ones you run regularly.",
            impact: "The model is downloaded again the next time code or an app asks for it.", restore: restore, lastUsed: date)
    }
}
