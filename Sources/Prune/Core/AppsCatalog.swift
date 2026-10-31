import AppKit
import Foundation

struct AppComponent: Hashable {
    enum Kind: String { case loginItem = "Login item", launchAgent = "Background agent", launchDaemon = "Root daemon", helper = "Privileged helper",
                        systemExtension = "System extension", appExtension = "App extension", externalAgent = "Installed agent" }
    var kind: Kind
    var name: String
    var path: String
}

struct AppEntry: Identifiable, Hashable {
    enum Arch: String { case universal = "Universal", appleSilicon = "Apple silicon", intel = "Intel only", legacy = "32-bit (can't run)", unknown = "Unknown" }
    enum Flag: String, Hashable {
        case unused = "Unused", neverOpened = "Never opened", intelOnly = "Intel only", cannotRun = "Can't run", unsigned = "Unsigned",
             damaged = "Damaged signature", duplicate = "Duplicate", installer = "Installer leftover", heavyHelpers = "Runs in background"
    }
    enum Move: Hashable { case movable, caution([String]), notMovable([String]) }

    var id: String { path }
    var path: String
    var name: String
    var bundleID: String
    var version: String
    var appSize: Int64
    var dataSize: Int64
    var dataPaths: [URL]
    var lastUsed: Date?
    var added: Date?
    var signer: SignatureInfo
    var appStore: Bool
    var arch: Arch
    var running: Bool
    var components: [AppComponent]
    var updater: String?
    var flags: [Flag]
    var move: Move
    var userOwned: Bool
    var isOffloaded = false
    var movableDataSize: Int64 = 0

    var url: URL { URL(fileURLWithPath: path) }
    var totalSize: Int64 { appSize + dataSize }
    var movableData: [URL] { dataPaths.filter { $0.path.contains("/Application Support/") } }
}

struct AddOn: Identifiable, Hashable {
    enum Kind: String, CaseIterable {
        case systemExtension = "System extensions", audioDriver = "Audio drivers", appExtension = "App extensions", quickLook = "Quick Look plug-ins",
             spotlight = "Spotlight importers", prefPane = "Preference panes", internetPlugin = "Internet plug-ins", screenSaver = "Screen savers",
             inputMethod = "Input methods", kext = "Kernel extensions"
    }
    enum State: Int, Comparable { case ok = 0, outdated, dangling
        static func < (a: State, b: State) -> Bool { a.rawValue < b.rawValue } }

    var id: String { path + name }
    var kind: Kind
    var name: String
    var path: String
    var bundleID: String
    var owner: String?
    var state: State
    var note: String
    var signer: SignatureInfo?
    var active: Bool = true
    var needsAdmin: Bool { path.hasPrefix("/Library/") }
    var removable: Bool { kind != .systemExtension && kind != .appExtension && FS.exists(URL(fileURLWithPath: path)) }
}

enum AppsCatalog {
    static func arch(of exe: String) -> AppEntry.Arch {
        guard let h = FileHandle(forReadingAtPath: exe), let d = try? h.read(upToCount: 4096), d.count >= 8 else { return .unknown }
        try? h.close()
        func be32(_ o: Int) -> UInt32 { d.withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(fromByteOffset: o, as: UInt32.self)) } }
        func le32(_ o: Int) -> UInt32 { d.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: o, as: UInt32.self)) } }
        var types: [UInt32] = []
        let magicBE = be32(0)
        if magicBE == 0xCAFEBABE || magicBE == 0xCAFEBABF {
            let n = Int(be32(4))
            let stride = magicBE == 0xCAFEBABE ? 20 : 32
            for i in 0..<min(n, 8) where 8 + i * stride + 4 <= d.count { types.append(be32(8 + i * stride)) }
        } else if [0xFEEDFACE, 0xFEEDFACF].contains(le32(0)) {
            types.append(le32(4))
        } else { return .unknown }
        let arm = types.contains(0x0100000C), x64 = types.contains(0x01000007)
        if arm && x64 { return .universal }
        if arm { return .appleSilicon }
        if x64 { return .intel }
        return types.isEmpty ? .unknown : .legacy
    }

    static func load(progress: @escaping (String) -> Void) -> [AppEntry] {
        let fm = FileManager.default
        var urls: [URL] = []
        for root in ["/Applications", "/Applications/Utilities", FS.home.appendingPathComponent("Applications").path] {
            for u in FS.children(URL(fileURLWithPath: root)) {
                if u.pathExtension == "app" { urls.append(u) }
                else if FS.isDir(u) && !u.lastPathComponent.hasPrefix(".") && u.lastPathComponent != "Utilities" { urls += FS.children(u).filter { $0.pathExtension == "app" } }
            }
        }
        let offloaded = Set(OffloadRegistry.load().map(\.source))
        let running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.resolvingSymlinksInPath().path })
        let externalPlists: [(String, [String: Any])] = [FS.home.path + "/Library/LaunchAgents", "/Library/LaunchAgents", "/Library/LaunchDaemons"].flatMap { dir in
            FS.children(URL(fileURLWithPath: dir)).compactMap { u -> (String, [String: Any])? in
                guard let d = try? Data(contentsOf: u), let p = try? PropertyListSerialization.propertyList(from: d, format: nil) as? [String: Any] else { return nil }
                return (u.path, p)
            }
        }
        let helpers = FS.children(URL(fileURLWithPath: "/Library/PrivilegedHelperTools")).map(\.path)
        progress("Reading \(urls.count) apps…")
        var out = [AppEntry?](repeating: nil, count: urls.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: urls.count) { i in
            let u = urls[i]
            let resolved = u.resolvingSymlinksInPath()
            guard let b = Bundle(url: resolved), let id = b.bundleIdentifier else { return }
            if resolved.path.hasPrefix("/System/") { return }   // Safari & co. are system components
            let info = b.infoDictionary ?? [:]
            let name = u.deletingPathExtension().lastPathComponent
            let exe = b.executableURL?.path ?? ""
            let vendor = id.split(separator: ".").prefix(2).joined(separator: ".")
            var comps: [AppComponent] = []
            func add(_ kind: AppComponent.Kind, _ dir: String, ext: String) {
                for c in FS.children(resolved.appendingPathComponent(dir)) where c.pathExtension == ext || ext.isEmpty {
                    comps.append(AppComponent(kind: kind, name: c.deletingPathExtension().lastPathComponent, path: c.path))
                }
            }
            add(.loginItem, "Contents/Library/LoginItems", ext: "app")
            add(.launchAgent, "Contents/Library/LaunchAgents", ext: "plist")
            add(.launchDaemon, "Contents/Library/LaunchDaemons", ext: "plist")
            add(.helper, "Contents/Library/LaunchServices", ext: "")
            add(.systemExtension, "Contents/Library/SystemExtensions", ext: "systemextension")
            add(.appExtension, "Contents/PlugIns", ext: "appex")
            for (plist, p) in externalPlists {
                let label = p["Label"] as? String ?? ""
                let program = (p["Program"] as? String) ?? (p["ProgramArguments"] as? [String])?.first ?? ""
                if program.hasPrefix(u.path + "/") || program.hasPrefix(resolved.path + "/") || (vendor.count > 6 && label.lowercased().hasPrefix(vendor.lowercased()) && !vendor.hasPrefix("com.apple")) {
                    comps.append(AppComponent(kind: plist.hasPrefix("/Library/LaunchDaemons") ? .launchDaemon : .externalAgent, name: label, path: plist))
                }
            }
            for h in helpers where (h as NSString).lastPathComponent.lowercased().hasPrefix(vendor.lowercased()) && vendor.count > 6 {
                comps.append(AppComponent(kind: .helper, name: (h as NSString).lastPathComponent, path: h))
            }
            let data = AppsScanner.leftovers(bundleID: id, appName: name).filter { !$0.path.contains("/Containers/") || SystemInfo.hasFullDiskAccess() }
            let appSize = Spotlight.physicalSize(resolved) ?? Sizer.measure(resolved).bytes
            let dataSizes = Sizer.measureMany(data)
            let dataSize = dataSizes.values.reduce(0) { $0 + $1.bytes }
            let movableDataSize = data.filter { $0.path.contains("/Application Support/") }.reduce(Int64(0)) { $0 + (dataSizes[$1]?.bytes ?? 0) }
            let sig = CodeSigning.check(resolved.path)
            let store = FS.exists(resolved.appendingPathComponent("Contents/_MASReceipt"))
            let a = arch(of: exe)
            let lastUsed = Spotlight.lastUsed(u)
            let added = Spotlight.attribute(u, "kMDItemDateAdded") as? Date
            var updater: String?
            if store { updater = "App Store" }
            else if FS.exists(resolved.appendingPathComponent("Contents/Frameworks/Sparkle.framework")) { updater = "Sparkle (updates in place)" }
            else if FS.exists(resolved.appendingPathComponent("Contents/Frameworks/Squirrel.framework")) { updater = "Squirrel (updates in place)" }
            else if id.hasPrefix("com.google.") { updater = "Google Updater (expects /Applications)" }
            else if id.hasPrefix("com.microsoft.") { updater = "Microsoft AutoUpdate (expects /Applications)" }

            var flags: [AppEntry.Flag] = []
            let days = Age.days(lastUsed ?? added) ?? 0
            if lastUsed == nil && (Age.days(added) ?? 0) > 30 { flags.append(.neverOpened) } else if days >= 90 { flags.append(.unused) }
            if a == .intel { flags.append(.intelOnly) }
            if a == .legacy { flags.append(.cannotRun) }
            if sig.trust == .invalid { flags.append(.damaged) } else if sig.isAnonymous { flags.append(.unsigned) }
            if name.lowercased().contains("install") || name.lowercased().hasPrefix("uninstall") { flags.append(.installer) }
            if comps.contains(where: { [.loginItem, .launchAgent, .launchDaemon, .externalAgent].contains($0.kind) }) { flags.append(.heavyHelpers) }

            let isRunning = running.contains(resolved.path)
            var blockers: [String] = []
            var cautions: [String] = []
            if id.hasPrefix("com.apple.") { blockers.append("Apple apps are managed by macOS and the App Store.") }
            if comps.contains(where: { $0.kind == .systemExtension }) { blockers.append("It installs a system extension, which macOS only loads from /Applications.") }
            if comps.contains(where: { $0.kind == .helper || $0.kind == .launchDaemon }) { blockers.append("It has root-level helpers registered to its current location.") }
            if store { blockers.append("Mac App Store apps update in place. Use App Store › Settings › \u{201C}Download and install large apps to a separate disk\u{201D} instead.") }
            if !comps.filter({ [.loginItem, .launchAgent, .externalAgent].contains($0.kind) }).isEmpty { cautions.append("Starts at login. The link Prune leaves keeps that working, but only while the drive is connected.") }
            if let u = updater, u.contains("expects /Applications") { cautions.append("Its updater (\(u.components(separatedBy: " (").first ?? u)) may refuse to update it outside /Applications.") }
            if appSize < 200 * 1_048_576 { cautions.append("Small app (\(Fmt.bytes(appSize))), so there's little to gain.") }
            let move: AppEntry.Move = !blockers.isEmpty ? .notMovable(blockers) : (cautions.isEmpty ? .movable : .caution(cautions))
            let entry = AppEntry(path: u.path, name: name, bundleID: id, version: (info["CFBundleShortVersionString"] as? String) ?? "", appSize: appSize,
                                 dataSize: dataSize, dataPaths: data, lastUsed: lastUsed, added: added, signer: sig, appStore: store, arch: a,
                                 running: isRunning, components: comps, updater: updater, flags: flags, move: move,
                                 userOwned: fm.isWritableFile(atPath: u.deletingLastPathComponent().path) && ((try? fm.attributesOfItem(atPath: u.path)[.ownerAccountID] as? NSNumber)?.intValue == Int(getuid())),
                                 isOffloaded: FS.isSymlink(u) && offloaded.contains(u.path), movableDataSize: movableDataSize)
            lock.lock(); out[i] = entry; lock.unlock()
        }
        var apps = out.compactMap { $0 }
        // Duplicates: the same bundle id installed more than once.
        let dupes = Dictionary(grouping: apps, by: \.bundleID).filter { $0.value.count > 1 }.keys
        for i in apps.indices where dupes.contains(apps[i].bundleID) { apps[i].flags.append(.duplicate) }
        return apps.sorted { $0.totalSize > $1.totalSize }
    }

    // MARK: Add-ons

    static func addOns(apps: [AppEntry], index: AppIndex) -> [AddOn] {
        var out: [AddOn] = []
        let h = FS.home.path
        func ownerFor(_ bundleID: String) -> String? {
            if bundleID.lowercased().hasPrefix("com.apple.") { return "macOS" }
            if let a = apps.first(where: { bundleID.lowercased().hasPrefix($0.bundleID.lowercased()) }) { return a.name }
            let vendor = bundleID.split(separator: ".").prefix(2).joined(separator: ".").lowercased()
            return apps.first { $0.bundleID.lowercased().hasPrefix(vendor) && vendor.count > 6 && !vendor.hasPrefix("com.apple") }?.name
        }
        func bundleInfo(_ u: URL) -> (String, String) {
            let b = Bundle(url: u)
            return (b?.bundleIdentifier ?? u.deletingPathExtension().lastPathComponent,
                    (b?.infoDictionary?["CFBundleName"] as? String) ?? u.deletingPathExtension().lastPathComponent)
        }

        // System extensions (network filters, drivers, endpoint security).
        let sx = Shell.run("/usr/bin/systemextensionsctl", ["list"], timeout: 10).stdout
        for line in sx.split(separator: "\n") where line.contains("[activated") || line.contains("[terminated") || line.contains("[uninstall") {
            let cols = line.split(separator: "\t").map(String.init)
            guard cols.count >= 5 else { continue }
            let bid = cols[3].components(separatedBy: " (").first ?? cols[3]
            let owner = apps.first { app in app.components.contains { $0.kind == .systemExtension && $0.path.contains(bid) } }?.name ?? ownerFor(bid)
            let active = line.contains("activated enabled")
            out.append(AddOn(kind: .systemExtension, name: cols[4], path: bid, bundleID: bid, owner: owner,
                             state: owner == nil ? .dangling : .ok,
                             note: owner == nil ? "Still \(active ? "active" : "installed"), but no installed app owns it. Driver and network extensions run with deep system access."
                                                : "Belongs to \(owner!). Team \(cols[2]).",
                             signer: nil, active: active))
        }
        // Folder-based add-ons
        let dirs: [(AddOn.Kind, [String], String)] = [
            (.audioDriver, ["/Library/Audio/Plug-Ins/HAL", h + "/Library/Audio/Plug-Ins/HAL"], "driver"),
            (.quickLook, ["/Library/QuickLook", h + "/Library/QuickLook"], "qlgenerator"),
            (.spotlight, ["/Library/Spotlight", h + "/Library/Spotlight"], "mdimporter"),
            (.prefPane, ["/Library/PreferencePanes", h + "/Library/PreferencePanes"], "prefPane"),
            (.internetPlugin, ["/Library/Internet Plug-Ins", h + "/Library/Internet Plug-Ins"], "plugin"),
            (.screenSaver, ["/Library/Screen Savers", h + "/Library/Screen Savers"], "saver"),
            (.inputMethod, ["/Library/Input Methods", h + "/Library/Input Methods"], "app"),
            (.kext, ["/Library/Extensions"], "kext"),
        ]
        let appleShippedKexts: Set<String> = ["HighPointIOP", "HighPointRR", "ATTOCelerityFC8", "ATTOExpressSASHBA2", "ATTOExpressSASRAID2", "ArcMSR",
                                              "CalDigitHDProDrv", "PromiseSTEX", "SoftRAID", "ACS6x", "BJUSBLoad", "LSI_FC", "LSI_SAS"]
        for (kind, folders, ext) in dirs {
            for folder in folders {
                for u in FS.children(URL(fileURLWithPath: folder)) where u.pathExtension == ext {
                    let (bid, name) = bundleInfo(u)
                    let owner = ownerFor(bid)
                    var state: AddOn.State = .ok
                    var note = owner.map { "Belongs to \($0)." } ?? ""
                    switch kind {
                    case .quickLook: state = .outdated; note = "Quick Look generators (.qlgenerator) are no longer loaded by current macOS. This one does nothing."
                    case .internetPlugin: state = .outdated; note = "Browsers stopped loading these plug-ins years ago."
                    case .kext:
                        if appleShippedKexts.contains(u.deletingPathExtension().lastPathComponent) { note = "Shipped with macOS for storage controllers. Leave it." }
                        else { state = .outdated; note = "A legacy kernel extension. Apple silicon Macs don't load these unless security is reduced." }
                    default:
                        if owner == nil { state = .dangling; note = "No installed app owns it. It was probably left behind by an uninstalled app." }
                    }
                    if kind == .audioDriver && owner == nil { note = "A virtual audio device driver with no installed app. It shows up as an audio device and loads into the audio system." }
                    out.append(AddOn(kind: kind, name: name, path: u.path, bundleID: bid, owner: owner, state: state, note: note,
                                     signer: CodeSigning.check(u.path)))
                }
            }
        }
        // A stale registration can survive even when its host app still exists after an update.
        let pk = Shell.run("/usr/bin/pluginkit", ["-mADvv"], timeout: 20).stdout
        let mounted = Set(SystemInfo.volumes().map(\.url.path))
        out += PluginRegistry.staleAddOns(pk, mounted: mounted)
        return out.sorted { ($0.state, $0.kind.rawValue) > ($1.state, $1.kind.rawValue) }
    }
}
