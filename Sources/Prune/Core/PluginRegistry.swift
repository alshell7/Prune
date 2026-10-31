import Foundation

/// PlugInKit's path-specific registrations; a bundle identifier can have several copies.
enum PluginRegistry {
    struct Registration: Hashable {
        var identifier: String
        var path: String
        var ignored: Bool
    }

    static func parse(_ output: String) -> [Registration] {
        let header = try! NSRegularExpression(pattern: #"^\s*([+!=?\-]?)\s*([A-Za-z0-9_][A-Za-z0-9_.-]*)\("#)
        var identifier: String?
        var ignored = false
        var result: [Registration] = []
        for line in output.components(separatedBy: .newlines) {
            let ns = line as NSString
            if let match = header.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
                identifier = ns.substring(with: match.range(at: 2))
                ignored = ns.substring(with: match.range(at: 1)) == "-"
            } else {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("Path = "), let identifier else { continue }
                let path = String(trimmed.dropFirst("Path = ".count))
                if path.hasPrefix("/") { result.append(Registration(identifier: identifier, path: path, ignored: ignored)) }
            }
        }
        return result
    }

    static func volumeAvailable(for path: String, mounted: Set<String>) -> Bool {
        let parts = path.split(separator: "/")
        guard parts.count >= 2, parts[0] == "Volumes" else { return true }
        return mounted.contains("/Volumes/" + parts[1])
    }

    static func staleAddOns(_ output: String, mounted: Set<String>) -> [AddOn] {
        parse(output).compactMap { registration in
            let path = registration.path, id = registration.identifier
            guard !path.hasPrefix("/System/"), !id.lowercased().hasPrefix("com.apple."), !path.contains("/Xcode.app/"),
                  !FS.exists(URL(fileURLWithPath: path)), volumeAvailable(for: path, mounted: mounted) else { return nil }
            let host = ProcessCatalog.outermostApp(path)
            let owner = host.flatMap { FS.exists(URL(fileURLWithPath: $0)) ? URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent : nil }
            let note = registration.ignored ? "This missing extension path is disabled. macOS may eventually remove the registration."
                : (owner == nil ? "The app and extension path are missing, but macOS still has a PlugInKit registration."
                   : "The app is present, but this registered extension path no longer exists. Another version may be installed.")
            return AddOn(kind: .appExtension, name: id, path: path, bundleID: id, owner: owner, state: .dangling,
                         note: note, active: !registration.ignored)
        }
    }

    enum Outcome { case removed, disabled }

    /// -r requires a bundle at the original path on macOS. For genuinely missing bundles,
    /// fall back to PlugInKit's ignore election, but only if it cannot disable a live copy.
    static func removeStale(_ addOn: AddOn,
                            mounted: Set<String> = Set(SystemInfo.volumes().map(\.url.path)),
                            run: ([String]) -> ShellResult = { Shell.run("/usr/bin/pluginkit", $0, timeout: 20) }) -> (Outcome?, String) {
        guard addOn.kind == .appExtension, addOn.state == .dangling,
              !addOn.bundleID.lowercased().hasPrefix("com.apple."), addOn.path.hasPrefix("/"),
              addOn.path.hasSuffix(".appex"), volumeAvailable(for: addOn.path, mounted: mounted) else {
            return (nil, "This registration is protected or its drive is disconnected.")
        }
        func query() -> (ShellResult, [Registration]) {
            var result = run(["-mADvv", "-i", addOn.bundleID])
            let parsed = parse(result.stdout)
            if result.ok && parsed.isEmpty && !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                !result.stdout.localizedCaseInsensitiveContains("no matches") {
                result.status = -1
                result.stderr = "Unrecognized PlugInKit registry output."
            }
            return (result, parsed.filter { $0.identifier == addOn.bundleID })
        }
        let (initialQuery, initial) = query()
        guard initialQuery.ok else { return (nil, "Couldn't query PlugInKit: \(initialQuery.stderr)") }
        guard initial.contains(where: { $0.path == addOn.path }) else { return (.removed, "The stale registration is already gone.") }
        guard initial.allSatisfy({ volumeAvailable(for: $0.path, mounted: mounted) && !FS.exists(URL(fileURLWithPath: $0.path)) }) else {
            return (nil, "Another copy exists or is on a disconnected drive. No registration was changed.")
        }
        guard !FS.exists(URL(fileURLWithPath: addOn.path)) else { return (nil, "The extension has reappeared; nothing was changed.") }
        let removal = run(["-r", addOn.path])
        if removal.ok {
            let (checked, remaining) = query()
            guard checked.ok else { return (nil, "PlugInKit returned success, but its registry could not be checked.") }
            if !remaining.contains(where: { $0.path == addOn.path }) { return (.removed, "Removed the stale PlugInKit registration.") }
        }
        // Elections apply to every version with this identifier. Recheck immediately before changing it.
        let (rechecked, current) = query()
        guard rechecked.ok, current.allSatisfy({ volumeAvailable(for: $0.path, mounted: mounted) && !FS.exists(URL(fileURLWithPath: $0.path)) }) else {
            return (nil, "The registry changed or a copy is available. Nothing was disabled.")
        }
        if !current.contains(where: { $0.path == addOn.path }) { return (.removed, "The stale registration is already gone.") }
        let election = run(["-e", "ignore", "-i", addOn.bundleID])
        guard election.ok else { return (nil, "macOS couldn't remove or disable this registration: \(election.stderr)") }
        let (verified, remaining) = query()
        guard verified.ok else { return (nil, "PlugInKit did not confirm whether the registration was disabled.") }
        if !remaining.contains(where: { $0.path == addOn.path }) { return (.removed, "Removed the stale PlugInKit registration.") }
        guard remaining.allSatisfy(\.ignored) else { return (nil, "PlugInKit did not confirm that all stale copies were disabled.") }
        return (.disabled, "Disabled the stale registration. macOS may remove it from the registry later.")
    }
}
