import AppKit
import Foundation
import Observation

enum AppInfo {
    static let repo = "alshell7/Prune"
    static let repoURL = URL(string: "https://github.com/\(repo)")!
    static let maintainer = "alshell7"
    static let maintainerURL = URL(string: "https://github.com/alshell7")!
    static let fallbackVersion = "1.1.1"
    static var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? fallbackVersion }
    static var build: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "dev" }

    static let license = """
    MIT License

    Copyright (c) 2026 alshell7

    Permission is hereby granted, free of charge, to any person obtaining a copy
    of this software and associated documentation files (the "Software"), to deal
    in the Software without restriction, including without limitation the rights
    to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
    copies of the Software, and to permit persons to whom the Software is
    furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all
    copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
    FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
    LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
    OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
    SOFTWARE.
    """
}

struct Release: Equatable {
    var version: String
    var name: String
    var notes: String
    var page: URL?
    var zipURL: URL?
    var checksumURL: URL?
    var published: Date?
}

enum UpdateLogic {
    /// Numeric, dot-separated comparison ("1.10.0" > "1.9.2"); a leading "v" and pre-release suffixes are ignored.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ v: String) -> [Int] {
            v.trimmingCharacters(in: CharacterSet(charactersIn: "vV ")).split(separator: "-").first.map { $0.split(separator: ".").map { Int($0) ?? 0 } } ?? []
        }
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    static func parse(_ data: Data) -> Release? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let tag = obj["tag_name"] as? String else { return nil }
        let assets = obj["assets"] as? [[String: Any]] ?? []
        func asset(_ suffix: String) -> URL? {
            assets.first { ($0["name"] as? String)?.hasSuffix(suffix) == true }.flatMap { ($0["browser_download_url"] as? String).flatMap(URL.init(string:)) }
        }
        return Release(version: tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV")), name: obj["name"] as? String ?? tag, notes: obj["body"] as? String ?? "",
                       page: (obj["html_url"] as? String).flatMap(URL.init(string:)), zipURL: asset(".zip"), checksumURL: asset(".zip.sha256"),
                       published: (obj["published_at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) })
    }

    /// Download hosts a release may come from.
    static func trustedHost(_ url: URL) -> Bool {
        guard url.scheme == "https", let h = url.host else { return false }
        return h == "github.com" || h.hasSuffix(".githubusercontent.com") || h == "api.github.com"
    }
}

@MainActor
@Observable
final class Updater {
    static let shared = Updater()

    enum State: Equatable {
        case idle, checking, upToDate, available(Release), downloading, installing, failed(String)
    }

    var state: State = .idle
    var lastCheck: Date? { didSet { UserDefaults.standard.set(lastCheck, forKey: "updateLastCheck") } }
    var autoCheck: Bool { didSet { UserDefaults.standard.set(autoCheck, forKey: "updateAutoCheck") } }
    var autoInstall: Bool { didSet { UserDefaults.standard.set(autoInstall, forKey: "updateAutoInstall") } }

    private init() {
        let d = UserDefaults.standard
        autoCheck = d.object(forKey: "updateAutoCheck") as? Bool ?? true
        autoInstall = d.object(forKey: "updateAutoInstall") as? Bool ?? false
        lastCheck = d.object(forKey: "updateLastCheck") as? Date
    }

    var available: Release? { if case .available(let r) = state { return r }; return nil }

    /// On launch and daily while running.
    func startSchedule() {
        guard !DemoMode.active else { return }
        Task {
            while !Task.isCancelled {
                if autoCheck, Date().timeIntervalSince(lastCheck ?? .distantPast) > 20 * 3600 { await check(quiet: true) }
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }

    func check(quiet: Bool = false) async {
        guard state != .checking, state != .downloading, state != .installing else { return }
        state = .checking
        let result = await AppModel.background { Self.fetchLatest() }
        lastCheck = Date()
        switch result {
        case .success(let r?) where UpdateLogic.isNewer(r.version, than: AppInfo.version):
            state = .available(r)
            if autoInstall { await install(r) }
            else if quiet { Notifier.post(title: "Prune \(r.version) is available", body: "Open Prune › About to update.") }
        case .success:
            state = .upToDate
        case .failure(let e):
            state = quiet ? .idle : .failed(e.localizedDescription)
        }
    }

    struct UpdateError: LocalizedError { var message: String; var errorDescription: String? { message } }

    nonisolated static func fetchLatest() -> Result<Release?, UpdateError> {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(AppInfo.repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Prune/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 20
        let sem = DispatchSemaphore(value: 0)
        var out: (Data?, Int) = (nil, 0)
        URLSession.shared.dataTask(with: req) { data, resp, _ in out = (data, (resp as? HTTPURLResponse)?.statusCode ?? 0); sem.signal() }.resume()
        sem.wait()
        if out.1 == 200, let data = out.0 { return .success(UpdateLogic.parse(data)) }
        // A private repository answers 404 to anonymous requests; the GitHub CLI can read it with your login.
        if out.1 == 404, let gh = Shell.which("gh") {
            let r = Shell.run(gh, ["api", "repos/\(AppInfo.repo)/releases/latest"], timeout: 20)
            if r.ok { return .success(UpdateLogic.parse(Data(r.stdout.utf8))) }
            if r.stdout.contains("Not Found") || r.stderr.contains("404") { return .success(nil) }
            return .failure(UpdateError(message: "GitHub CLI: \(r.stderr.prefix(200))"))
        }
        if out.1 == 404 { return .success(nil) }
        return .failure(UpdateError(message: out.1 == 0 ? "No connection to GitHub." : "GitHub answered \(out.1)."))
    }

    func install(_ r: Release) async {
        state = .downloading
        let outcome = await AppModel.background { Self.downloadAndVerify(r) }
        switch outcome {
        case .failure(let e): state = .failed(e.message)
        case .success(let app):
            state = .installing
            Self.relaunch(replacingWith: app)
        }
    }

    /// Downloads the release zip, checks its SHA-256, unpacks it and verifies the bundle before anything is replaced.
    nonisolated static func downloadAndVerify(_ r: Release) -> Result<URL, UpdateError> {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("PruneUpdate-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let zip = work.appendingPathComponent("Prune.zip"), sum = work.appendingPathComponent("Prune.zip.sha256")
        func fetch(_ url: URL?, to dest: URL) -> Bool {
            guard let url, UpdateLogic.trustedHost(url) else { return false }
            if Shell.run("/usr/bin/curl", ["-fsSL", "--max-time", "300", "-o", dest.path, url.absoluteString], timeout: 320).ok { return true }
            // Private repository: let the GitHub CLI authenticate the download.
            guard let gh = Shell.which("gh") else { return false }
            return Shell.run(gh, ["release", "download", "v" + r.version, "-R", AppInfo.repo, "-p", url.lastPathComponent, "-O", dest.path, "--clobber"], timeout: 320).ok
        }
        guard fetch(r.zipURL, to: zip) else { return .failure(UpdateError(message: "Couldn't download the update.")) }
        guard fetch(r.checksumURL, to: sum), let expected = (try? String(contentsOf: sum, encoding: .utf8))?.split(separator: " ").first.map(String.init),
              expected.count == 64 else { return .failure(UpdateError(message: "The release has no checksum, so Prune won't install it.")) }
        let actual = Shell.run("/usr/bin/shasum", ["-a", "256", zip.path], timeout: 60).stdout.split(separator: " ").first.map(String.init) ?? ""
        guard actual.lowercased() == expected.lowercased() else { return .failure(UpdateError(message: "Checksum mismatch: the download is corrupt or was altered.")) }
        let unpacked = work.appendingPathComponent("unpacked")
        guard Shell.run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path], timeout: 120).ok,
              let app = FS.children(unpacked).first(where: { $0.pathExtension == "app" }) else { return .failure(UpdateError(message: "The archive doesn't contain Prune.app.")) }
        let info = Bundle(url: app)?.infoDictionary
        guard info?["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier ?? "app.prune.mac" else { return .failure(UpdateError(message: "The update has a different bundle identifier.")) }
        guard let v = info?["CFBundleShortVersionString"] as? String, UpdateLogic.isNewer(v, than: AppInfo.version) else { return .failure(UpdateError(message: "The download isn't newer than this version.")) }
        guard Shell.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path], timeout: 60).ok else { return .failure(UpdateError(message: "The update's code signature is invalid.")) }
        _ = Shell.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path], timeout: 30)
        return .success(app)
    }

    /// Swaps the bundle after Prune quits (the old copy goes to the Trash), then reopens it.
    static func relaunch(replacingWith newApp: URL) {
        let current = Bundle.main.bundleURL
        let q = Shell.shellQuote
        let script = """
        while kill -0 \(getpid()) 2>/dev/null; do sleep 0.3; done
        backup=\(q(current.path)).old-$$
        mv \(q(current.path)) "$backup" && /usr/bin/ditto \(q(newApp.path)) \(q(current.path)) && { osascript -e "tell application \\"Finder\\" to delete POSIX file \\"$backup\\"" >/dev/null 2>&1 || rm -rf "$backup"; } || { rm -rf \(q(current.path)); mv "$backup" \(q(current.path)); }
        open \(q(current.path))
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        try? p.run()
        NSApp.terminate(nil)
    }
}
