import Foundation

/// System extensions (DriverKit drivers, network and endpoint-security extensions) as macOS records them in
/// /Library/SystemExtensions/db.plist, plus a plan for removing one whose app is gone.
struct SystemExtensionRecord: Hashable {
    var identifier: String
    var teamID: String
    var state: String
    var version: String
    var originPath: String?
    var categories: [String]

    var containerApp: String? {
        guard let p = originPath, let r = p.range(of: ".app/") else { return nil }
        return String(p[..<r.lowerBound]) + ".app"
    }
    var containerExists: Bool { containerApp.map { FileManager.default.fileExists(atPath: $0) } ?? false }
    var isEnabled: Bool { state.contains("enabled") }
    var isActive: Bool { state.hasPrefix("activated") }
    var vendorPrefix: String { identifier.split(separator: ".").prefix(2).joined(separator: ".") }
    var kindLabel: String {
        if categories.contains(where: { $0.contains("driver") }) { return "Driver extension" }
        if categories.contains(where: { $0.contains("network") }) { return "Network extension" }
        if categories.contains(where: { $0.contains("endpoint") }) { return "Endpoint security extension" }
        return "System extension"
    }
}

enum SystemExtensions {
    static let dbPath = "/Library/SystemExtensions/db.plist"

    static func records(plist path: String = dbPath) -> [SystemExtensionRecord] {
        guard let data = FileManager.default.contents(atPath: path),
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let list = root["extensions"] as? [[String: Any]] else { return [] }
        return list.compactMap { e in
            guard let id = e["identifier"] as? String else { return nil }
            let bundleVersion = e["bundleVersion"] as? [String: Any]
            return SystemExtensionRecord(identifier: id, teamID: e["teamID"] as? String ?? "", state: e["state"] as? String ?? "",
                                         version: bundleVersion?["CFBundleShortVersionString"] as? String ?? "",
                                         originPath: e["originPath"] as? String, categories: e["categories"] as? [String] ?? [])
        }
    }

    static var sipEnabled: Bool { Shell.run("/usr/bin/csrutil", ["status"], timeout: 5).stdout.contains("enabled") }

    /// Support files a vendor's product leaves behind. Only offered when no installed app from the same vendor remains.
    static func leftovers(for r: SystemExtensionRecord, installedBundleIDs: [String]) -> [URL] {
        let vendor = r.vendorPrefix.lowercased()
        guard vendor.count > 6, !vendor.hasPrefix("com.apple"),
              !installedBundleIDs.contains(where: { $0.lowercased().hasPrefix(vendor + ".") }) else { return [] }
        let h = FS.home.path
        var out: [URL] = []
        let exact = ["/Library/Application Support/\(r.vendorPrefix)", h + "/Library/Application Support/\(r.vendorPrefix)"]
        out += exact.map(URL.init(fileURLWithPath:)).filter(FS.exists)
        for dir in ["/Library/LaunchDaemons", "/Library/LaunchAgents", h + "/Library/LaunchAgents", "/Library/PrivilegedHelperTools"] {
            out += FS.children(URL(fileURLWithPath: dir)).filter { $0.lastPathComponent.lowercased().hasPrefix(vendor + ".") }
        }
        return out
    }

    /// Asks macOS to uninstall (works only with System Integrity Protection off).
    static func uninstall(_ r: SystemExtensionRecord) -> ShellResult {
        Shell.runAsAdmin("/usr/bin/systemextensionsctl uninstall \(Shell.shellQuote(r.teamID)) \(Shell.shellQuote(r.identifier))")
    }

    static func openSettings() {
        _ = Shell.run("/usr/bin/open", ["x-apple.systempreferences:com.apple.LoginItems-Settings.extension"], timeout: 5)
    }

    static let vendorUninstallers: [String: (name: String, url: String)] = [
        "org.pqrs": ("Karabiner-Elements", "https://karabiner-elements.pqrs.org/docs/manual/operation/uninstall/"),
        "at.obdev": ("Little Snitch", "https://help.obdev.at/littlesnitch5/lsc-uninstallation"),
        "com.objective-see": ("Objective-See tools", "https://objective-see.org/products.html"),
        "io.tailscale": ("Tailscale", "https://tailscale.com/kb/1069/uninstall"),
        "com.wireguard": ("WireGuard", "https://www.wireguard.com/install/"),
    ]
}

extension PluginRegistry {
    /// Enables or disables a third-party app extension (PlugInKit election), then verifies it.
    static func setEnabled(_ addOn: AddOn, _ on: Bool, run: ([String]) -> ShellResult = { Shell.run("/usr/bin/pluginkit", $0, timeout: 20) }) -> (Bool, String) {
        guard addOn.kind == .appExtension, !addOn.bundleID.lowercased().hasPrefix("com.apple.") else { return (false, "Apple extensions are managed by macOS.") }
        let r = run(["-e", on ? "use" : "ignore", "-i", addOn.bundleID])
        guard r.ok else { return (false, "PlugInKit refused: \(r.stderr)") }
        let check = parse(run(["-mAvv", "-i", addOn.bundleID]).stdout).filter { $0.identifier == addOn.bundleID }
        guard !check.isEmpty, check.allSatisfy({ $0.ignored == !on }) else { return (false, "PlugInKit did not confirm the change.") }
        return (true, on ? "Enabled \(addOn.name)." : "Disabled \(addOn.name). The host app stops loading it.")
    }

    /// Third-party app extensions that are installed and registered (Finder Sync, Share, widgets, Safari…).
    static func installedThirdParty(_ output: String) -> [AddOn] {
        var out: [AddOn] = []
        var seen = Set<String>()
        // SDK (extension point) per path, read from each record's key = value lines.
        var sdkFor: [String: String] = [:]
        var path: String?, sdk: String?
        for line in output.components(separatedBy: .newlines) + [""] {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("Path = ") { path = String(t.dropFirst(7)) }
            else if t.hasPrefix("SDK = ") { sdk = String(t.dropFirst(6)) }
            else if t.isEmpty { if let p = path, let s = sdk { sdkFor[p] = s }; path = nil; sdk = nil }
        }
        for r in parse(output) where !r.identifier.lowercased().hasPrefix("com.apple.") && !r.path.hasPrefix("/System/") && FS.exists(URL(fileURLWithPath: r.path)) {
            guard seen.insert(r.identifier).inserted else { continue }
            let host = ProcessCatalog.outermostApp(r.path)
            let owner = host.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }
            if r.path.contains("/Xcode.app/") { continue }
            let sdk = sdkFor[r.path] ?? ""
            out.append(AddOn(kind: .appExtension, name: friendly(sdk) + (owner.map { " · \($0)" } ?? ""), path: r.path, bundleID: r.identifier, owner: owner,
                             state: .ok, note: "\(friendly(sdk)) extension from \(owner ?? "an app"). \(r.ignored ? "Disabled." : "Enabled.")", active: !r.ignored))
        }
        return out
    }

    static func friendly(_ sdk: String) -> String {
        let table = ["com.apple.FinderSync": "Finder Sync", "com.apple.share-services": "Share menu", "com.apple.widgetkit-extension": "Widget",
                     "com.apple.Safari.web-extension": "Safari extension", "com.apple.Safari.extension": "Safari extension", "com.apple.quicklook.preview": "Quick Look preview",
                     "com.apple.quicklook.thumbnail": "Quick Look thumbnail", "com.apple.fileprovider-nonui": "File Provider", "com.apple.services": "Services menu",
                     "com.apple.photo-editing": "Photos editing", "com.apple.intents-service": "Siri & Shortcuts", "com.apple.authentication-services-credential-provider-ui": "Password AutoFill",
                     "com.apple.spotlight.import": "Spotlight importer", "com.apple.usernotifications.service": "Notifications", "com.apple.appintents-extension": "App Intents"]
        return table[sdk] ?? (sdk.isEmpty ? "App extension" : sdk.replacingOccurrences(of: "com.apple.", with: ""))
    }
}
