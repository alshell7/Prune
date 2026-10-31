import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Renders Prune's own windows to images (no screen-recording permission needed), for the README demos.
@MainActor
enum WindowCapture {
    static func image(of window: NSWindow) -> CGImage? {
        guard let view = window.contentView?.superview ?? window.contentView else { return nil }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        // Render the composited layer tree (cacheDisplay misses layer-drawn content such as sidebar rows).
        if let layer = view.layer {
            let scale = window.backingScaleFactor
            let size = CGSize(width: view.bounds.width * scale, height: view.bounds.height * scale)
            if let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                ctx.scaleBy(x: scale, y: scale)
                if !view.isFlipped { } // CALayer.render draws in layer coordinates; macOS layers are not flipped.
                layer.render(in: ctx)
                if let img = ctx.makeImage() { return img }
            }
        }
        let rect = view.bounds
        guard let rep = view.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
        view.cacheDisplay(in: rect, to: rep)
        return rep.cgImage
    }

    static func writePNG(_ image: CGImage, to url: URL) {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }

    static var mainWindow: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue.contains("main") == true && $0.isVisible } ?? NSApp.windows.first { $0.isVisible && $0.contentView != nil && $0.frame.width > 800 }
    }
}

import SwiftUI

/// README captures: the same sidebar entries, drawn with the active-window selection style.
struct CaptureSidebarList: View {
    let sidebar: Sidebar
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(sidebar.sections.indices, id: \.self) { i in
                    let section = sidebar.sections[i]
                    if let title = section.title {
                        Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.leading, 10).padding(.top, 12).padding(.bottom, 3)
                    }
                    ForEach(section.entries) { e in
                        let selected = model.route == e.route
                        sidebar.row(e)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .foregroundStyle(selected ? Color.white : Color.primary)
                            .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.accentColor : .clear))
                            .id(e.route)
                    }
                }
            }
            .padding(.horizontal, 10).padding(.bottom, 10)
        }
        .clipped()
        .onChange(of: model.route) { _, r in if let r { proxy.scrollTo(r, anchor: .center) } }
        }
    }
}

enum DemoMode {
    static let active = UserDefaults.standard.bool(forKey: "PruneDemo")
}

extension DemoData {
    @MainActor static func install() {
        let m = AppModel.shared
        m.refreshVolumes()
        m.items = items
        m.hasScanned = true
        m.hasFDA = true
        m.scanDuration = 11.4
        let sec = SecurityModel.shared
        sec.report = security; sec.scannedAt = Date(); sec.focused = security.findings.first?.id
        SecretsModel.shared.report = secrets
        SecretsModel.shared.focused = secrets.files.first?.id
        let cb = CodeBackupModel.shared
        cb.repos = repos; cb.checkedAt = Date(); cb.focused = repos.first?.id
        DoctorModel.shared.issues = doctor; DoctorModel.shared.checkedAt = Date()
        AppsModel.shared.apps = apps; AppsModel.shared.addOns = addOns
        let g = ModuleGuide.shared
        g.dismissed = Set(ModuleGuide.catalog.map(\.key)); g.forced = nil; g.showTour = false
    }
}

/// Drives the real UI through scripted scenarios and records frames for the README (`-PruneShots <dir>`).
@MainActor
final class DemoDirector {
    struct Frame { var file: String; var duration: Double }
    let root: URL
    var scene = ""
    var frames: [Frame] = []
    var previous: CGImage?
    var index = 0
    /// The last capture without a sheet: a window with an attached sheet stops drawing its own content.
    var lastMain: CGImage?

    init(root: URL) { self.root = root }

    var model: AppModel { AppModel.shared }

    func begin(_ name: String) {
        scene = name; frames = []; previous = nil; index = 0
        try? FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
    }

    func settle(_ seconds: Double = 0.7) async { try? await Task.sleep(for: .seconds(seconds)) }

    func grab() -> CGImage? {
        guard let w = WindowCapture.mainWindow, var img = WindowCapture.image(of: w) else { return nil }
        if w.attachedSheet == nil { lastMain = img }
        if let sheet = w.attachedSheet, let simg = WindowCapture.image(of: sheet) {
            img = lastMain ?? img
            let scale = CGFloat(img.width) / w.frame.width
            let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
            ctx.setFillColor(CGColor(gray: 0, alpha: 0.18)); ctx.fill(CGRect(x: 0, y: 0, width: img.width, height: img.height))
            let x = (sheet.frame.minX - w.frame.minX) * scale, y = (sheet.frame.minY - w.frame.minY) * scale
            ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 30, color: CGColor(gray: 0, alpha: 0.35))
            ctx.draw(simg, in: CGRect(x: x, y: y, width: CGFloat(simg.width), height: CGFloat(simg.height)))
            img = ctx.makeImage() ?? img
        }
        return img
    }

    /// Captures the current state, crossfading from the previous one. `cursor` is in window points from the top-left.
    func snap(_ hold: Double, cursor: CGPoint? = nil, click: Bool = false) async {
        await settle()
        guard let img = grab() else { return }
        let decorated = cursor.map { draw(cursor: $0, click: click, on: img) } ?? img
        if let prev = previous, prev.width == decorated.width, prev.height == decorated.height {
            for a in [0.25, 0.5, 0.75] { write(blend(prev, decorated, a), 0.05) }
        }
        write(decorated, hold)
        previous = decorated
    }

    /// Records live animation (e.g. an explainer card) at `fps`.
    func film(seconds: Double, fps: Double = 12) async {
        await settle(0.3)
        let n = Int(seconds * fps)
        for _ in 0..<n {
            if let img = grab() { write(img, 1 / fps); previous = img }
            try? await Task.sleep(for: .seconds(1 / fps))
        }
    }

    func still(_ name: String, window: NSWindow? = nil) async {
        await settle(0.9)
        guard let w = window ?? WindowCapture.mainWindow, let img = WindowCapture.image(of: w) else { return }
        WindowCapture.writePNG(img, to: root.appendingPathComponent(name + ".png"))
    }

    func end() {
        var list = "ffconcat version 1.0\n"
        for f in frames { list += "file '\(f.file)'\nduration \(String(format: "%.3f", f.duration))\n" }
        if let last = frames.last { list += "file '\(last.file)'\n" }
        try? list.write(to: root.appendingPathComponent(scene).appendingPathComponent("list.txt"), atomically: true, encoding: .utf8)
    }

    private func write(_ img: CGImage, _ duration: Double) {
        let name = String(format: "f%04d.png", index); index += 1
        WindowCapture.writePNG(img, to: root.appendingPathComponent(scene).appendingPathComponent(name))
        frames.append(Frame(file: name, duration: duration))
    }

    private func context(_ w: Int, _ h: Int) -> CGContext {
        CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }

    private func blend(_ a: CGImage, _ b: CGImage, _ t: Double) -> CGImage {
        let ctx = context(a.width, a.height), r = CGRect(x: 0, y: 0, width: a.width, height: a.height)
        ctx.draw(a, in: r); ctx.setAlpha(t); ctx.draw(b, in: r)
        return ctx.makeImage() ?? b
    }

    private func draw(cursor p: CGPoint, click: Bool, on img: CGImage) -> CGImage {
        guard let w = WindowCapture.mainWindow else { return img }
        let scale = CGFloat(img.width) / w.frame.width
        let ctx = context(img.width, img.height), r = CGRect(x: 0, y: 0, width: img.width, height: img.height)
        ctx.draw(img, in: r)
        // Window points (top-left origin) → image pixels (bottom-left origin); titlebar included in the capture.
        let x = p.x * scale, y = CGFloat(img.height) - p.y * scale
        if click {
            ctx.setFillColor(CGColor(red: 0.23, green: 0.51, blue: 0.96, alpha: 0.25))
            ctx.fillEllipse(in: CGRect(x: x - 16 * scale, y: y - 16 * scale, width: 32 * scale, height: 32 * scale))
        }
        if let cur = NSCursor.arrow.image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let size = NSCursor.arrow.image.size, hot = NSCursor.arrow.hotSpot
            ctx.draw(cur, in: CGRect(x: x - hot.x * scale, y: y - (size.height - hot.y) * scale, width: size.width * scale, height: size.height * scale))
        }
        return ctx.makeImage() ?? img
    }

    // MARK: Script

    func run(openWindow: @escaping (String) -> Void) async {
        NSApp.activate(ignoringOtherApps: true)
        if let w = WindowCapture.mainWindow {
            w.titleVisibility = .hidden
            w.setContentSize(NSSize(width: 1360, height: 800))
            w.center()
            w.makeKeyAndOrderFront(nil)
        }
        let guide = ModuleGuide.shared
        func hideGuides() { guide.dismissed = Set(ModuleGuide.catalog.map(\.key)); guide.forced = nil }
        hideGuides()

        // 1. Scan → results → review → space back.
        begin("overview")
        DemoData.cleaned = false; model.refreshVolumes()
        model.items = []; model.hasScanned = false; model.route = .overview
        await snap(1.6)
        model.isScanning = true
        model.finishedScanners = Set(model.scanners.prefix(5).map(\.name)); model.scannerStatus = DemoData.scannerStatus()
        await snap(1.0)
        model.finishedScanners = Set(model.scanners.prefix(11).map(\.name))
        await snap(0.9)
        model.isScanning = false; model.hasScanned = true; model.items = DemoData.items
        await snap(2.4)
        let rec = model.items.filter { $0.isActionable && $0.recommendation == .recommended }
        model.selection = Set(rec.map(\.id))
        model.review(rec)
        await snap(2.8)
        model.showReview = false
        DemoData.cleaned = true; model.refreshVolumes(); SpaceHistory.shared.reloadDemo()
        model.items.removeAll { rec.map(\.id).contains($0.id) }; model.selection = []
        await snap(2.6)
        end()

        // 2. Every drive gets its own suggestions.
        DemoData.cleaned = false; model.refreshVolumes(); model.items = DemoData.items
        begin("drives")
        let artifacts = model.items.filter { $0.category == .projectArtifacts }
        model.diskScope = nil
        model.open(.category(.projectArtifacts), focus: artifacts.first { $0.title.hasPrefix("pixel-forge") }?.id)
        await snap(2.0)
        model.diskScope = DemoData.ssd
        model.route = .overview; await settle(0.2)
        model.open(.category(.projectArtifacts), focus: artifacts.first { $0.title.hasPrefix("ml-notebooks") }?.id)
        await snap(2.6)
        model.route = .overview
        await snap(2.2)
        model.diskScope = nil
        end()

        // 3. Secrets.
        begin("secrets")
        let sm = SecretsModel.shared
        sm.filter = .issues; sm.focused = sm.report.files.first?.id
        model.route = .secrets
        await snap(2.4)
        sm.focused = sm.report.files.first { $0.origin == .home }?.id
        await snap(2.0)
        sm.focused = sm.report.files.first?.id
        if let i = sm.report.files.indices.first { sm.report.files[i].git = .ignored }
        sm.toast = (true, "Git no longer tracks .env (the file is still on disk). Added /.env to .gitignore. Rotate the keys: they remain in git history.")
        await snap(2.8)
        sm.toast = nil; SecretsModel.shared.report = DemoData.secrets
        end()

        // 4. Code Backup.
        begin("backup")
        let cb = CodeBackupModel.shared
        cb.focused = cb.repos.first?.id
        model.route = .codeBackup
        await snap(2.2)
        cb.focused = cb.repos.first { $0.level == .unpushed }?.id
        await snap(2.2)
        cb.focused = cb.repos.first { $0.level == .noRemote }?.id
        await snap(2.0)
        end()

        // 5. Project Doctor, then a dangling driver.
        begin("doctor")
        model.route = .doctor
        await snap(2.6)
        let am = AppsModel.shared
        am.tab = .addOns; am.focusedAddOn = am.addOns.first?.id
        model.route = .apps
        await snap(2.8)
        end()

        // 6. A how-it-works card, live.
        begin("explainer")
        guide.dismissed.remove("secrets"); model.route = .secrets
        await settle(0.4)
        await film(seconds: 4.0)
        end()
        hideGuides()

        // Stills.
        model.route = .timeline; await still("timeline")
        model.route = .maintenance; await still("maintenance")
        model.route = .overview; await still("overview-light")
        // The toolbar's glass can't be rendered offscreen in dark mode, so dark stills go without it.
        WindowCapture.mainWindow?.toolbar?.isVisible = false
        NSApp.appearance = NSAppearance(named: .darkAqua)
        model.route = .secrets; await still("secrets-dark")
        model.route = .overview; await still("overview-dark")
        NSApp.appearance = nil
        WindowCapture.mainWindow?.toolbar?.isVisible = true
        openWindow("about"); await settle(1.0)
        if let about = NSApp.windows.first(where: { $0.title == "About Prune" || $0.identifier?.rawValue.contains("about") == true }) { await still("about", window: about); about.close() }
        try? "done".write(to: root.appendingPathComponent("DONE"), atomically: true, encoding: .utf8)
        NSApp.terminate(nil)
    }
}
