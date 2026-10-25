import Foundation

/// `Prune --selftest-offload`: moves a fixture project to a scratch APFS disk image and back.
/// Uses its own registry file; touches nothing of yours.
enum OffloadSelfTest {
    static func run() -> Int32 {
        SelfTest.failures = 0
        AuditLog.enabled = false
        let fm = FileManager.default
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("prune-offload-test-\(getpid())")
        try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        OffloadRegistry.file = tmp.appendingPathComponent("offloads.json")
        let base = FS.home.appendingPathComponent(".prune-offload-selftest-\(getpid())")
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)

        print("Scratch drive")
        let image = tmp.appendingPathComponent("drive")
        let create = Shell.run("/usr/bin/hdiutil", ["create", "-size", "400m", "-fs", "APFS", "-volname", "PruneOffloadTest", "-type", "SPARSE", image.path], timeout: 120)
        let attach = Shell.run("/usr/bin/hdiutil", ["attach", "-nobrowse", image.path + ".sparseimage"], timeout: 120)
        let mount = attach.stdout.split(separator: "\n").map(String.init).compactMap { line -> String? in
            guard let r = line.range(of: "/Volumes/") else { return nil }
            return String(line[r.lowerBound...]).trimmingCharacters(in: .whitespaces)
        }.last
        SelfTest.check("created and mounted an APFS image", create.ok && mount != nil, mount ?? create.stderr + attach.stderr)
        defer {
            if let mount { Shell.run("/usr/bin/hdiutil", ["detach", "-force", mount], timeout: 60) }
            try? fm.removeItem(at: tmp)
            _ = Shell.run("/bin/chmod", ["-R", "u+w", base.path])
            try? fm.removeItem(at: base)
        }
        guard let mount else { return 1 }
        let destRoot = URL(fileURLWithPath: mount).appendingPathComponent("Prune Offload")

        print("Fixture project")
        let proj = base.appendingPathComponent("webapp")
        func write(_ rel: String, _ bytes: Int, random: Bool = false) {
            let u = proj.appendingPathComponent(rel)
            try? fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            var data = Data(count: bytes)
            if random { data.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, bytes, $0.baseAddress!) } }
            fm.createFile(atPath: u.path, contents: data)
        }
        write("package.json", 64); write("package-lock.json", 64); write("src/index.js", 2048, random: true)
        write("assets/video.bin", 40_000_000, random: true)
        write("node_modules/left-pad/index.js", 3_000_000)
        try? "node_modules/\n".write(to: proj.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        write("bin/run.sh", 32); chmod(proj.appendingPathComponent("bin/run.sh").path, 0o755)
        try? fm.createSymbolicLink(atPath: proj.appendingPathComponent("entry.js").path, withDestinationPath: "src/index.js")
        Shell.run("/usr/bin/xattr", ["-w", "com.prune.test", "kept", proj.appendingPathComponent("src/index.js").path])
        let git = Git.tool ?? "/usr/bin/git"
        func g(_ args: [String], _ dir: URL) -> ShellResult { Shell.run(git, args, cwd: dir.path, timeout: 30) }
        _ = g(["init", "-q", "-b", "main"], proj)
        _ = g(["add", "-A"], proj)
        _ = g(["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "-m", "init"], proj)
        let wt = base.appendingPathComponent("webapp-feature")
        _ = g(["worktree", "add", "-q", wt.path, "-b", "feature"], proj)
        let srcHash = OffloadEngine.sha256(proj.appendingPathComponent("assets/video.bin").path)

        print("Guards")
        SelfTest.check("refuses ~/Documents itself", OffloadGuard.checkSource(FS.home.appendingPathComponent("Documents")) != nil)
        SelfTest.check("refuses app Library folders", OffloadGuard.checkSource(FS.home.appendingPathComponent("Library/Caches")) != nil)
        SelfTest.check("refuses the startup disk as destination", OffloadGuard.checkDestination(FS.home.appendingPathComponent("Documents")).problem != nil)
        SelfTest.check("accepts the APFS image", OffloadGuard.checkDestination(destRoot).problem == nil)

        print("Resume")
        // Pretend a previous run was interrupted: one file already copied, one left corrupted.
        let destProj = destRoot.appendingPathComponent(String(proj.path.dropFirst(FS.home.path.count + 1)))
        try? fm.createDirectory(at: destProj.appendingPathComponent("src"), withIntermediateDirectories: true)
        _ = copyfile(proj.appendingPathComponent("package.json").path, destProj.appendingPathComponent("package.json").path, nil, 0xF)
        fm.createFile(atPath: destProj.appendingPathComponent("src/index.js").path, contents: Data(repeating: 0x7A, count: 2048))

        print("Offload")
        var lastPhase = ""
        let engine = OffloadEngine { p in lastPhase = p.phase.rawValue }
        let (out, record) = engine.offload(OffloadRequest(source: proj, skipArtifacts: true, leaveLink: true),
                                           options: OffloadOptions(destinationRoot: destRoot, checksums: true), index: 1, count: 1)
        SelfTest.check("offload succeeds", out.success, out.message)
        SelfTest.check("original is now a link to the drive", FS.isSymlink(proj) && proj.resolvingSymlinksInPath().path == destProj.resolvingSymlinksInPath().path)
        SelfTest.check("node_modules left behind, not copied", !FS.exists(destProj.appendingPathComponent("node_modules")) && (record?.skipped.first?.restore == "npm ci"))
        SelfTest.check("big file checksum matches", OffloadEngine.sha256(destProj.appendingPathComponent("assets/video.bin").path) == srcHash)
        SelfTest.check("interrupted/corrupted file was replaced", OffloadEngine.sha256(destProj.appendingPathComponent("src/index.js").path)
                       == OffloadEngine.sha256(proj.appendingPathComponent("src/index.js").path))
        SelfTest.check("symlink preserved", (try? fm.destinationOfSymbolicLink(atPath: destProj.appendingPathComponent("entry.js").path)) == "src/index.js")
        SelfTest.check("extended attribute preserved", Shell.run("/usr/bin/xattr", ["-p", "com.prune.test", destProj.appendingPathComponent("src/index.js").path]).stdout.contains("kept"))
        let mode = (try? fm.attributesOfItem(atPath: destProj.appendingPathComponent("bin/run.sh").path)[.posixPermissions] as? NSNumber)?.intValue ?? 0
        SelfTest.check("permissions preserved", mode & 0o777 == 0o755, String(mode, radix: 8))
        SelfTest.check("git works through the link", g(["status", "--porcelain"], proj).stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        SelfTest.check("linked worktree still works", g(["status", "--porcelain"], wt).ok)
        SelfTest.check("recorded for bring-back", OffloadRegistry.load().count == 1)
        SelfTest.check("finished in Done phase", lastPhase == "Done")

        print("Bring back")
        if let record {
            let back = OffloadEngine { _ in }.bringBack(record, keepCopyOnDrive: false)
            SelfTest.check("bring back succeeds", back.success, back.message)
            SelfTest.check("original is a real folder again", FS.isDir(proj) && !FS.isSymlink(proj))
            SelfTest.check("contents intact", OffloadEngine.sha256(proj.appendingPathComponent("assets/video.bin").path) == srcHash)
            SelfTest.check("drive copy removed", !FS.exists(destProj))
            SelfTest.check("git clean after return", g(["status", "--porcelain"], proj).stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            SelfTest.check("worktree still works after return", g(["status", "--porcelain"], wt).ok)
            SelfTest.check("record cleared", OffloadRegistry.load().isEmpty)
        }

        print("Single file")
        let movie = base.appendingPathComponent("talk.mov")
        fm.createFile(atPath: movie.path, contents: Data(repeating: 0x42, count: 5_000_000))
        let (fo, frec) = OffloadEngine { _ in }.offload(OffloadRequest(source: movie, skipArtifacts: false, leaveLink: false),
                                                        options: OffloadOptions(destinationRoot: destRoot, checksums: true), index: 1, count: 1)
        SelfTest.check("file offload succeeds without a link", fo.success && !FS.exists(movie), fo.message)
        if let frec {
            let back = OffloadEngine { _ in }.bringBack(frec, keepCopyOnDrive: true)
            SelfTest.check("file comes back, drive copy kept", back.success && FS.exists(movie) && FS.exists(URL(fileURLWithPath: frec.destination)), back.message)
        }

        print("App Mover")
        // A real, signed app bundle: compiled now, ad-hoc signed like a self-built app.
        let appURL = base.appendingPathComponent("Apps/PruneTestApp.app")
        let macos = appURL.appendingPathComponent("Contents/MacOS")
        try? fm.createDirectory(at: macos, withIntermediateDirectories: true)
        try? fm.createDirectory(at: appURL.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": "app.prune.selftest.mover", "CFBundleExecutable": "PruneTestApp", "CFBundleName": "PruneTestApp",
                                   "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "1.0"]
        try? PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: appURL.appendingPathComponent("Contents/Info.plist"))
        try? Data(repeating: 0x5A, count: 3_000_000).write(to: appURL.appendingPathComponent("Contents/Resources/assets.bin"))
        let src = base.appendingPathComponent("hello.c")
        try? "#include <stdio.h>\nint main(void){puts(\"hello from moved app\");return 0;}\n".write(to: src, atomically: true, encoding: .utf8)
        _ = Shell.run("/usr/bin/xcrun", ["clang", "-o", macos.appendingPathComponent("PruneTestApp").path, src.path], timeout: 120)
        let sign = Shell.run("/usr/bin/codesign", ["--force", "--deep", "--sign", "-", appURL.path], timeout: 60)
        SelfTest.check("built and signed a test app", sign.ok, sign.stderr)
        let appEntry = AppEntry(path: appURL.path, name: "PruneTestApp", bundleID: "app.prune.selftest.mover", version: "1.0", appSize: 3_000_000, dataSize: 0,
                                dataPaths: [], lastUsed: nil, added: nil, signer: CodeSigning.check(appURL.path), appStore: false, arch: AppsCatalog.arch(of: macos.appendingPathComponent("PruneTestApp").path),
                                running: false, components: [], updater: nil, flags: [], move: .movable, userOwned: true)
        SelfTest.check("architecture detected", appEntry.arch == .appleSilicon || appEntry.arch == .universal, appEntry.arch.rawValue)
        let moved = OffloadEngine { _ in }.offloadApp(appEntry, moveData: false, options: OffloadOptions(destinationRoot: destRoot, checksums: true))
        let appDest = destRoot.appendingPathComponent("Applications/PruneTestApp.app")
        SelfTest.check("app moved to the drive", moved.first?.success == true, moved.first?.message ?? "")
        SelfTest.check("original replaced by a link", FS.isSymlink(appURL) && appURL.resolvingSymlinksInPath().path == appDest.resolvingSymlinksInPath().path)
        SelfTest.check("moved copy passes codesign --verify --deep --strict", Shell.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", appDest.path], timeout: 60).ok)
        let ran = Shell.run(appURL.appendingPathComponent("Contents/MacOS/PruneTestApp").path, [], timeout: 10)
        SelfTest.check("app still runs through the link", ran.stdout.contains("hello from moved app"), ran.stderr)
        if let rec = OffloadRegistry.load().first(where: { $0.source == appURL.path }) {
            let back = OffloadEngine { _ in }.bringBack(rec, keepCopyOnDrive: false)
            SelfTest.check("app brought back", back.success && FS.isDir(appURL) && !FS.isSymlink(appURL), back.message)
            SelfTest.check("returned app still verifies", Shell.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", appURL.path], timeout: 60).ok)
        } else { SelfTest.check("app move recorded", false) }
        let running = AppEntry(path: "/Applications/Nope.app", name: "Nope", bundleID: "x", version: "", appSize: 0, dataSize: 0, dataPaths: [], lastUsed: nil, added: nil,
                               signer: SignatureInfo(trust: .developerID), appStore: false, arch: .appleSilicon, running: false, components: [], updater: nil, flags: [],
                               move: .notMovable(["It installs a system extension."]), userOwned: true)
        SelfTest.check("refuses apps marked not movable", OffloadEngine { _ in }.offloadApp(running, moveData: false, options: OffloadOptions(destinationRoot: destRoot)).first?.success == false)

        print("In-use protection")
        let busy = base.appendingPathComponent("busy-project")
        try? fm.createDirectory(at: busy, withIntermediateDirectories: true)
        fm.createFile(atPath: busy.appendingPathComponent("server.log").path, contents: Data(count: 1000))
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["30"]
        sleeper.currentDirectoryURL = busy        // like a terminal or dev server running there
        try? sleeper.run()
        let (bo, _) = OffloadEngine { _ in }.offload(OffloadRequest(source: busy, skipArtifacts: false, leaveLink: true),
                                                     options: OffloadOptions(destinationRoot: destRoot, checksums: true), index: 1, count: 1)
        sleeper.terminate()
        SelfTest.check("refuses while a process works inside the folder", !bo.success && bo.message.contains("sleep") && FS.isDir(busy) && !FS.isSymlink(busy), bo.message)

        print(SelfTest.failures == 0 ? "\nAll offload checks passed." : "\n\(SelfTest.failures) offload check(s) failed.")
        return SelfTest.failures == 0 ? 0 : 1
    }
}
