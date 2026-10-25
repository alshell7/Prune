import AppKit
import Observation
import SwiftUI

struct OffloadChoice: Hashable { var link: Bool; var skip: Bool }

@MainActor
@Observable
final class OffloadModel {
    static let shared = OffloadModel()

    var destinations: [VolumeInfo] = []
    var customDestination: URL?
    var selectedVolume: String?          // volume path
    var candidates: [OffloadCandidate] = []
    var finding = false
    var findStatus = ""
    var selected: [String: OffloadChoice] = [:]
    var checksums = true
    var trashOriginals = false
    var running = false
    var progress = OffloadProgress()
    var outcomes: [OffloadOutcome] = []
    var records: [OffloadRecord] = []
    var showProgress = false
    var engine: OffloadEngine?

    func refresh() {
        destinations = SystemInfo.volumes().filter { !$0.isBoot }
        if selectedVolume == nil || !destinations.contains(where: { $0.url.path == selectedVolume }) {
            selectedVolume = destinations.max { $0.available < $1.available }?.url.path
        }
        records = OffloadRegistry.load()
    }

    var destinationRoot: URL? {
        if let c = customDestination { return c }
        return selectedVolume.map { URL(fileURLWithPath: $0).appendingPathComponent("Prune Offload") }
    }

    var destinationCheck: OffloadGuard.Destination? { destinationRoot.map(OffloadGuard.checkDestination) }

    func find(settings: SettingsSnapshot) {
        guard !finding else { return }
        finding = true
        findStatus = "Starting…"
        Task {
            let list = await AppModel.background {
                OffloadPlanner.candidates(settings: settings) { msg in Task { @MainActor in OffloadModel.shared.findStatus = msg } }
            }
            candidates = list
            finding = false
        }
    }

    func toggle(_ c: OffloadCandidate) {
        if selected[c.id] != nil { selected[c.id] = nil } else { selected[c.id] = OffloadChoice(link: c.defaultLink, skip: c.defaultSkip) }
    }

    /// Items nested inside another selected item are moved along with it.
    func isCovered(_ c: OffloadCandidate) -> Bool {
        selected.keys.contains { $0 != c.id && FS.isAncestor($0, of: c.id) }
    }

    var plan: [(OffloadCandidate, OffloadChoice)] {
        candidates.compactMap { c in selected[c.id].map { (c, $0) } }.filter { !isCovered($0.0) }
    }

    var planBytes: Int64 { plan.reduce(0) { $0 + $1.0.bytes } }
    var planSkipped: Int64 { plan.reduce(0) { $0 + ($1.1.skip ? $1.0.skippable : 0) } }

    func addCustom(_ url: URL) -> String? {
        if let problem = OffloadGuard.checkSource(url) { return problem }
        if candidates.contains(where: { $0.id == url.path }) { selected[url.path] = selected[url.path] ?? OffloadChoice(link: true, skip: true); return nil }
        let isProject = FS.exists(url.appendingPathComponent(".git")) || FS.exists(url.appendingPathComponent("package.json"))
        let c = OffloadCandidate(url: url, kind: isProject ? .project : .userFolder, bytes: 0, skippable: 0, lastActivity: nil,
                                 note: "Added by you · measuring…", defaultLink: true, defaultSkip: isProject, isGoodCandidate: true)
        candidates.insert(c, at: 0)
        selected[c.id] = OffloadChoice(link: true, skip: isProject)
        // Measure off the main thread so big folders don't freeze the window.
        Task {
            let size = await AppModel.background { Sizer.measure(url) }
            if let i = candidates.firstIndex(where: { $0.id == url.path }) {
                candidates[i].bytes = size.bytes
                candidates[i].lastActivity = size.newest
                candidates[i].note = "Added by you"
            }
        }
        return nil
    }

    func start() {
        guard let root = destinationRoot, !running else { return }
        let plan = self.plan
        running = true
        outcomes = []
        showProgress = true
        let options = OffloadOptions(destinationRoot: root, checksums: checksums, trashOriginals: trashOriginals)
        let engine = OffloadEngine { p in Task { @MainActor in OffloadModel.shared.progress = p } }
        self.engine = engine
        Task {
            let results = await AppModel.background { () -> [OffloadOutcome] in
                var out: [OffloadOutcome] = []
                for (i, (c, choice)) in plan.enumerated() {
                    if engine.isCancelled { break }
                    let req = OffloadRequest(source: c.url, skipArtifacts: choice.skip, leaveLink: choice.link, linkRequired: OffloadGuard.linkRequired(c.url))
                    out.append(engine.offload(req, options: options, index: i + 1, count: plan.count).0)
                }
                return out
            }
            outcomes = results
            running = false
            for o in results where o.success { selected[o.source.path] = nil; candidates.removeAll { $0.id == o.source.path } }
            records = OffloadRegistry.load()
            AppModel.shared.refreshVolumes()
            let moved = results.filter(\.success).reduce(Int64(0)) { $0 + $1.bytes + $1.skippedBytes }
            if moved > 0 { Notifier.post(title: "Offload finished", body: "\(Fmt.bytes(moved)) freed on your Mac.") }
        }
    }

    func bringBack(_ r: OffloadRecord, keepCopy: Bool) {
        guard !running else { return }
        running = true
        outcomes = []
        showProgress = true
        let engine = OffloadEngine { p in Task { @MainActor in OffloadModel.shared.progress = p } }
        self.engine = engine
        Task {
            let o = await AppModel.background { engine.bringBack(r, keepCopyOnDrive: keepCopy) }
            outcomes = [o]
            running = false
            records = OffloadRegistry.load()
            AppModel.shared.refreshVolumes()
        }
    }

    func cancel() { engine?.cancel() }
}

struct OffloadView: View {
    @Environment(AppModel.self) private var model
    @State private var off = OffloadModel.shared
    @State private var confirm = false
    @State private var bringBackRecord: OffloadRecord?
    @State private var keepCopy = false
    @State private var error: String?
    @State private var codeRisks: [String] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Offload to Drive").font(.largeTitle.weight(.bold))
                    Text("Move projects and folders to an external SSD to free space on your Mac. Prune copies, checksums every file, catches changes made during the copy, and only then swaps the original for a link. Your paths keep working while the drive is connected. Rebuildable folders (node_modules, target/, .next…) are left behind instead of copied.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                destinationCard
                candidatesSection
                if !off.records.isEmpty { recordsSection }
            }
            .padding(24)
            .frame(maxWidth: 1050, alignment: .leading)
        }
        .safeAreaInset(edge: .bottom) { if !off.selected.isEmpty { actionBar } }
        .navigationTitle("Offload")
        .onAppear {
            off.refresh()
            if off.candidates.isEmpty && !off.finding { off.find(settings: model.settings.snapshot) }
        }
        .sheet(isPresented: $off.showProgress) { OffloadProgressSheet() }
        .alert("Move \(off.plan.count) item\(off.plan.count == 1 ? "" : "s") to \(destinationName)?", isPresented: $confirm) {
            Button("Move \(Fmt.bytes(off.planBytes))") { off.start() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmMessage)
        }
        .alert("Bring back \(bringBackRecord.map { URL(fileURLWithPath: $0.source).lastPathComponent } ?? "")?", isPresented: Binding(get: { bringBackRecord != nil }, set: { if !$0 { bringBackRecord = nil } })) {
            Button("Bring Back") { if let r = bringBackRecord { off.bringBack(r, keepCopy: keepCopy) } }
            Button("Bring Back, Keep Drive Copy") { if let r = bringBackRecord { off.bringBack(r, keepCopy: true) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It's copied back to its original place and verified, then the link is replaced with the real folder.")
        }
        .alert("Can't add this", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") {} } message: { Text(error ?? "") }
    }

    private var confirmMessage: String {
        var parts: [String] = []
        if !codeRisks.isEmpty {
            parts.append("\u{26A0}\u{FE0F} The drive will hold the only copy of some source code. " + codeRisks.joined(separator: " ") + " Push it first if you can.\n")
        }
        parts.append("Each item is copied and verified before anything on your Mac changes.")
        if off.planSkipped > 0 { parts.append("\(Fmt.bytes(off.planSkipped)) of rebuildable folders will be deleted instead of copied.") }
        parts.append("Originals are \(off.trashOriginals ? "moved to the Trash" : "removed") after verification.")
        return parts.joined(separator: " ")
    }

    private var destinationName: String {
        if let c = off.customDestination { return c.lastPathComponent }
        return off.destinations.first { $0.url.path == off.selectedVolume }?.name ?? "the drive"
    }

    // MARK: Destination

    private var destinationCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Destination", systemImage: "externaldrive.fill").font(.headline)
                    Spacer()
                    Button("Refresh") { off.refresh() }
                    Button("Choose Folder…") {
                        if let u = Finder.chooseFolder(prompt: "Use as destination") { off.customDestination = u }
                    }
                }
                if off.destinations.isEmpty && off.customDestination == nil {
                    HStack(spacing: 10) {
                        Image(systemName: "cable.connector").font(.title2).foregroundStyle(.secondary)
                        Text("Connect an external drive. APFS-formatted SSDs work best for projects because they keep symlinks, permissions and git metadata exactly.")
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    if off.customDestination == nil {
                        Picker("Drive", selection: $off.selectedVolume) {
                            ForEach(off.destinations) { v in Text("\(v.name) · \(Fmt.bytes(v.available)) free").tag(Optional(v.url.path)) }
                        }
                        .pickerStyle(.radioGroup)
                    } else if let c = off.customDestination {
                        HStack {
                            Text(c.path).font(.callout.monospaced())
                            Button("Use a drive instead") { off.customDestination = nil }.buttonStyle(.link)
                        }
                    }
                    if let root = off.destinationRoot, let check = off.destinationCheck {
                        Text("Files go to \(root.path), keeping their path relative to your home folder. File system: \(check.fsType.uppercased()) · \(Fmt.bytes(check.free)) free.")
                            .font(.caption).foregroundStyle(.secondary)
                        if let p = check.problem { Label(p, systemImage: "xmark.octagon.fill").foregroundStyle(.red).font(.callout) }
                        ForEach(check.warnings, id: \.self) { w in Label(w, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout).fixedSize(horizontal: false, vertical: true) }
                    }
                }
                if !off.plan.isEmpty { transferPreview.transition(.opacity.combined(with: .move(edge: .top))) }
            }
            .animation(.snappy, value: off.plan.count)
        }
    }

    /// What the move does to both disks, live as you tick items.
    @ViewBuilder private var transferPreview: some View {
        if let mac = model.bootVolume {
            let drive = off.destinations.first { $0.url.path == off.selectedVolume }
            Divider().padding(.vertical, 4)
            HStack(alignment: .center, spacing: 14) {
                BeforeAfterBar(title: "Your Mac", icon: "laptopcomputer", total: mac.total, usedNow: mac.used,
                               usedAfter: max(0, mac.used - off.planBytes - off.planSkipped))
                Image(systemName: "arrow.right").font(.title3).foregroundStyle(.secondary)
                    .symbolEffect(.pulse, isActive: off.running)
                if let drive {
                    BeforeAfterBar(title: drive.name, icon: "externaldrive.fill", total: drive.total, usedNow: drive.used, usedAfter: drive.used + off.planBytes)
                }
            }
        }
    }

    // MARK: Candidates

    private var candidatesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("What to move").font(.title3.weight(.semibold))
                Spacer()
                if off.finding {
                    ProgressView().controlSize(.small)
                    Text(off.findStatus).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).frame(maxWidth: 280)
                }
                Button("Add Folder…") {
                    if let u = Finder.chooseFolder(prompt: "Offload") { error = off.addCustom(u) }
                }
                Button(off.candidates.isEmpty ? "Find Candidates" : "Refresh") { off.find(settings: model.settings.snapshot) }
                    .buttonStyle(.borderedProminent).disabled(off.finding)
            }
            if off.candidates.isEmpty && !off.finding {
                Text("Prune looks for projects you haven't touched in a while, big data folders inside projects, and large folders in Documents, Downloads and Desktop.")
                    .foregroundStyle(.secondary)
            }
            ForEach(OffloadCandidate.Kind.allCases, id: \.self) { kind in
                let list = off.candidates.filter { $0.kind == kind }
                if !list.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(kind.rawValue).font(.headline)
                        Text(kind.blurb).font(.caption).foregroundStyle(.secondary)
                        VStack(spacing: 0) {
                            ForEach(list) { c in candidateRow(c); Divider().padding(.leading, 40) }
                        }
                        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
        }
    }

    private func candidateRow(_ c: OffloadCandidate) -> some View {
        let choice = off.selected[c.id]
        let covered = off.isCovered(c)
        return HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: Binding(get: { choice != nil || covered }, set: { _ in off.toggle(c) }))
                .toggleStyle(.checkbox).labelsHidden().disabled(covered)
            Image(nsImage: NSWorkspace.shared.icon(forFile: c.url.path)).resizable().frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(c.title).lineLimit(1).truncationMode(.middle)
                    if c.isGoodCandidate { Text("Good candidate").font(.caption2.weight(.semibold)).foregroundStyle(.green)
                        .padding(.horizontal, 5).padding(.vertical, 1).background(Color.green.opacity(0.12), in: Capsule()) }
                }
                Text(covered ? "Moves along with the selected folder that contains it" : c.note).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                if let choice, !covered {
                    HStack(spacing: 14) {
                        Toggle("Leave a link in place", isOn: Binding(get: { choice.link || OffloadGuard.linkRequired(c.url) },
                                                                      set: { off.selected[c.id]?.link = $0 }))
                            .disabled(OffloadGuard.linkRequired(c.url))
                            .help("Keeps the original path working (for tools, IDEs and scripts) while the drive is connected.")
                        if c.skippable > 0 {
                            Toggle("Leave rebuildable folders behind (\(Fmt.bytes(c.skippable)))", isOn: Binding(get: { choice.skip }, set: { off.selected[c.id]?.skip = $0 }))
                                .help("node_modules, build outputs and caches are deleted instead of copied. Reinstall or rebuild them when you need the project again.")
                        }
                    }
                    .toggleStyle(.checkbox).font(.caption)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(Fmt.bytes(c.bytes + ((choice?.skip ?? c.defaultSkip) ? 0 : c.skippable))).font(.callout.monospacedDigit())
                if c.skippable > 0, choice?.skip ?? c.defaultSkip {
                    Text("+\(Fmt.bytes(c.skippable)) freed").font(.caption2.monospacedDigit()).foregroundStyle(.green)
                }
            }
            Button { Finder.reveal([c.url]) } label: { Image(systemName: "magnifyingglass") }.buttonStyle(.borderless)
        }
        .padding(.vertical, 8).padding(.horizontal, 12)
    }

    // MARK: Action bar

    private var actionBar: some View {
        let check = off.destinationCheck
        let fits = OffloadGuard.fits(need: off.planBytes, free: check?.free ?? 0)
        return HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(off.plan.count) item\(off.plan.count == 1 ? "" : "s") · \(Fmt.bytes(off.planBytes)) to copy").font(.callout.weight(.semibold))
                Text("Frees \(Fmt.bytes(off.planBytes + off.planSkipped)) on your Mac" + (fits ? "" : " · doesn't fit on the destination"))
                    .font(.caption).foregroundStyle(fits ? .secondary : Color.red)
            }
            Spacer()
            Toggle("Verify with checksums", isOn: $off.checksums).toggleStyle(.checkbox)
                .help("Reads every copied file back and compares SHA-256 hashes. Slower, but catches bad cables and failing drives.")
            Toggle("Trash originals instead of deleting", isOn: $off.trashOriginals).toggleStyle(.checkbox)
                .help("Extra safety: originals go to the Trash after verification, but the space is only freed when you empty it.")
            Button {
                codeRisks = off.plan.compactMap { CodeBackup.riskSummary(for: $0.0.url) }
                confirm = true
            } label: { Text("Move to \(destinationName)…") }
                .buttonStyle(.borderedProminent)
                .disabled(off.plan.isEmpty || off.destinationRoot == nil || check?.problem != nil || !fits || off.running)
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(.bar)
    }

    // MARK: Records

    private var recordsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("On your drives").font(.title3.weight(.semibold))
            VStack(spacing: 0) {
                ForEach(off.records) { r in
                    let connected = FS.exists(URL(fileURLWithPath: r.destination))
                    HStack(spacing: 10) {
                        Image(systemName: connected ? "externaldrive.fill.badge.checkmark" : "externaldrive.badge.xmark")
                            .foregroundStyle(connected ? .green : .orange).frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(FS.tildePath(URL(fileURLWithPath: r.source))).lineLimit(1).truncationMode(.middle)
                            Text("\(r.volumeName) · moved \(Fmt.ago(r.date)) · \(r.linked ? "linked" : "no link")\(r.checksummed ? " · checksum-verified" : "")\(r.skipped.isEmpty ? "" : " · \(r.skipped.count) rebuildable folder(s) left behind")\(connected ? "" : " · drive not connected")")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Text(Fmt.bytes(r.bytes)).font(.callout.monospacedDigit())
                        Button("Reveal") { Finder.reveal([URL(fileURLWithPath: r.destination)]) }.disabled(!connected)
                        Button("Bring Back…") { keepCopy = false; bringBackRecord = r }.disabled(!connected || off.running)
                        Menu {
                            if !r.skipped.isEmpty {
                                Section("Rebuild after bringing back") {
                                    ForEach(r.skipped, id: \.self) { s in Text("\(s.path): \(s.restore ?? s.kind)") }
                                }
                            }
                            Button("Forget This Record") { OffloadRegistry.remove(r.id); off.refresh() }
                        } label: { Image(systemName: "ellipsis.circle") }
                            .menuStyle(.borderlessButton).fixedSize()
                    }
                    .padding(.vertical, 8).padding(.horizontal, 12)
                    Divider().padding(.leading, 46)
                }
            }
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

struct OffloadProgressSheet: View {
    @State private var off = OffloadModel.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if off.running {
                let p = off.progress
                Text(p.itemCount > 1 ? "Moving \(p.itemIndex) of \(p.itemCount): \(p.item)" : "Moving \(p.item)").font(.title3.weight(.semibold))
                Text(p.phase.rawValue).foregroundStyle(.secondary)
                if p.bytesTotal > 0 {
                    ProgressView(value: Double(min(p.bytesDone, p.bytesTotal)), total: Double(p.bytesTotal))
                    HStack {
                        Text("\(Fmt.bytes(p.bytesDone)) of \(Fmt.bytes(p.bytesTotal))").monospacedDigit()
                        Spacer()
                        if p.bytesPerSecond > 0 {
                            let eta = Double(p.bytesTotal - p.bytesDone) / p.bytesPerSecond
                            Text("\(Fmt.bytes(Int64(p.bytesPerSecond)))/s · \(eta < 60 ? "<1 min" : "\(Int(eta / 60)) min") left").monospacedDigit()
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
                Text(p.current).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                HStack {
                    Text("Cancelling is safe: nothing on your Mac changes until an item is verified.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { off.cancel() }
                }
            } else {
                let ok = off.outcomes.filter(\.success)
                Label(ok.count == off.outcomes.count ? "All done" : "\(ok.count) of \(off.outcomes.count) moved",
                      systemImage: ok.count == off.outcomes.count ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(ok.count == off.outcomes.count ? .green : .orange)
                if !ok.isEmpty {
                    Text("Freed \(Fmt.bytes(ok.reduce(0) { $0 + $1.bytes + $1.skippedBytes })) on your Mac.").foregroundStyle(.secondary)
                }
                List(off.outcomes) { o in
                    VStack(alignment: .leading, spacing: 2) {
                        Label(FS.tildePath(o.source), systemImage: o.success ? "checkmark" : "xmark").foregroundStyle(o.success ? .primary : Color.red)
                        Text(o.message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(minHeight: 160)
                HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
            }
        }
        .padding(22)
        .frame(width: 560)
        .interactiveDismissDisabled(off.running)
    }
}
