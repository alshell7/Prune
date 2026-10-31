import Foundation

/// Safe, well-known macOS maintenance commands, each explained before it runs.
struct MaintenanceTask: Identifiable, Hashable {
    enum Effect: String { case space = "Frees space", fix = "Fixes glitches", check = "Read-only check" }
    var id: String
    var title: String
    var symbol: String
    var effect: Effect
    var what: String
    var when: String
    var impact: String
    var needsAdmin: Bool
    /// Shell command line (run through /bin/sh, or as administrator).
    var command: String
    var timeout: TimeInterval = 120
    /// Optional read-only probe that describes the current state ("3 local snapshots").
    var probe: (() -> String?)? = nil

    static func == (a: Self, b: Self) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

enum Maintenance {
    static let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

    static let tasks: [MaintenanceTask] = [
        MaintenanceTask(id: "snapshots", title: "Thin local Time Machine snapshots", symbol: "clock.arrow.2.circlepath", effect: .space,
                        what: "Deletes the local APFS snapshots Time Machine keeps on the startup disk between backups.",
                        when: "System Data looks huge, or free space doesn't come back after deleting files.",
                        impact: "Your real backups on the backup disk are untouched. Only the local hourly copies go.",
                        needsAdmin: true, command: "/usr/bin/tmutil thinlocalsnapshots / 999999999999 4", timeout: 300,
                        probe: {
                            let n = Shell.run("/usr/bin/tmutil", ["listlocalsnapshots", "/"], timeout: 15).stdout.split(separator: "\n").filter { $0.contains("com.apple") }.count
                            return n == 0 ? "No local snapshots" : "\(n) local snapshot\(n == 1 ? "" : "s")"
                        }),
        MaintenanceTask(id: "dns", title: "Flush DNS cache", symbol: "network", effect: .fix,
                        what: "Clears cached hostname lookups and restarts the DNS responder.",
                        when: "A site moved servers, a local dev domain resolves wrongly, or VPN switching left stale answers.",
                        impact: "The next few lookups are a few milliseconds slower.",
                        needsAdmin: true, command: "/usr/bin/dscacheutil -flushcache; /usr/bin/killall -HUP mDNSResponder"),
        MaintenanceTask(id: "launchservices", title: "Rebuild Open With menu", symbol: "arrow.up.forward.app", effect: .fix,
                        what: "Re-registers apps with Launch Services, the database behind \u{201C}Open With\u{201D} and default apps.",
                        when: "Open With shows duplicates or apps you deleted, or files open in the wrong app.",
                        impact: "Takes a minute. Default-app choices are kept.",
                        needsAdmin: false, command: "\(lsregister) -r -domain local -domain system -domain user", timeout: 300),
        MaintenanceTask(id: "quicklook", title: "Reset Quick Look", symbol: "eye", effect: .fix,
                        what: "Clears Quick Look's thumbnail cache and reloads its preview generators.",
                        when: "Previews or Finder thumbnails are blank, stale or wrong.",
                        impact: "Thumbnails regenerate as you browse.",
                        needsAdmin: false, command: "/usr/bin/qlmanage -r cache >/dev/null; /usr/bin/qlmanage -r >/dev/null"),
        MaintenanceTask(id: "purge", title: "Free inactive memory", symbol: "memorychip", effect: .space,
                        what: "Flushes the disk cache from memory (the purge command), which can let macOS shrink swap files.",
                        when: "Swap is large and the Mac feels sluggish after heavy builds or VMs.",
                        impact: "Apps may feel slower for a minute while caches refill.",
                        needsAdmin: true, command: "/usr/sbin/purge",
                        probe: {
                            let out = Shell.run("/usr/sbin/sysctl", ["-n", "vm.swapusage"], timeout: 5).stdout
                            return out.split(separator: " ").firstIndex(of: "used").flatMap { i in i + 2 < out.split(separator: " ").count ? "Swap used: " + out.split(separator: " ")[i + 2] : nil }
                        }),
        MaintenanceTask(id: "dock", title: "Restart Dock and Finder", symbol: "dock.rectangle", effect: .fix,
                        what: "Relaunches the Dock, Finder and the menu bar's system UI.",
                        when: "Mission Control, the Dock or Finder windows stop responding or redraw incorrectly.",
                        impact: "Finder windows reopen; nothing is lost.",
                        needsAdmin: false, command: "/usr/bin/killall Dock; /usr/bin/killall Finder; /usr/bin/killall SystemUIServer"),
        MaintenanceTask(id: "fonts", title: "Clear font caches", symbol: "textformat", effect: .fix,
                        what: "Removes your account's font cache databases.",
                        when: "Text renders garbled, or a font you installed doesn't appear.",
                        impact: "Takes effect after you log out or restart.",
                        needsAdmin: false, command: "/usr/bin/atsutil databases -removeUser"),
        MaintenanceTask(id: "verify", title: "Verify startup disk", symbol: "checkmark.seal", effect: .check,
                        what: "Runs Disk Utility's read-only file system check on the startup volume.",
                        when: "After crashes, power loss, or odd file errors.",
                        impact: "Read-only. The disk may be briefly slower.",
                        needsAdmin: false, command: "/usr/sbin/diskutil verifyVolume /", timeout: 900),
        MaintenanceTask(id: "spotlight", title: "Rebuild Spotlight index", symbol: "magnifyingglass", effect: .fix,
                        what: "Erases and rebuilds the startup disk's Spotlight index.",
                        when: "Spotlight can't find files you know exist, or mds is stuck using CPU.",
                        impact: "Search is incomplete for a while (up to hours) and indexing uses CPU.",
                        needsAdmin: true, command: "/usr/bin/mdutil -E /", timeout: 120),
    ]

    static func run(_ task: MaintenanceTask) -> ShellResult {
        let r = task.needsAdmin ? Shell.runAsAdmin(task.command) : Shell.run("/bin/sh", ["-c", task.command], timeout: task.timeout)
        AuditLog.append([CleanOutcome(title: task.title, category: "Maintenance", paths: [], size: 0, method: task.needsAdmin ? "Administrator command" : "Command",
                                      success: r.ok, message: r.ok ? "Completed" : String((r.stderr.isEmpty ? r.stdout : r.stderr).prefix(300)))])
        UserDefaults.standard.set(Date(), forKey: "maintenance.\(task.id)")
        return r
    }

    static func lastRun(_ task: MaintenanceTask) -> Date? { UserDefaults.standard.object(forKey: "maintenance.\(task.id)") as? Date }
}
