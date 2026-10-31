import AppKit
import SwiftUI

struct DuplicatesView: View {
    @Environment(AppModel.self) private var model
    @State private var report: DuplicateFinder.Report?
    @State private var scanning = false
    @State private var busy = false
    @State private var status = ""
    @State private var message: String?
    @State private var pending: (file: DuplicateFinder.File, keep: DuplicateFinder.File)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "doc.on.doc").font(.system(size: 26)).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Duplicate Finder").font(.title2.weight(.semibold))
                    Text("Find matching files of at least 10 MB in your selected scan locations. Prune compares file contents and leaves every copy in place until you choose one.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button { scan() } label: {
                    if scanning { ProgressView().controlSize(.small) } else { Label(report == nil ? "Find Duplicates" : "Scan Again", systemImage: "magnifyingglass") }
                }.buttonStyle(.borderedProminent).disabled(scanning || busy)
            }
            .padding(16)
            Divider()
            if scanning {
                VStack(spacing: 10) { ProgressView(); Text(status).font(.callout).foregroundStyle(.secondary) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let report {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(report.groups.count) matching groups · \(report.filesConsidered) large files considered").font(.callout.weight(.medium))
                        Text("Files are verified with SHA-256. Actual space recovered may differ on APFS clones or after moving to Trash.")
                            .font(.caption).foregroundStyle(.secondary)
                        if report.incomplete || report.unreadable > 0 {
                            Text("Scan incomplete: \(report.skippedForBudget) files exceeded the 8 GB verification budget; \(report.unreadable) items were unreadable or changed. Directory and file limits may also apply.")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }.padding(14)
                    Divider()
                    if report.groups.isEmpty {
                        EmptyStateView(symbol: "doc.on.doc", title: "No verified duplicates found", message: "Try another scan location or check the coverage note above.")
                    } else {
                        List {
                            ForEach(report.groups) { group in
                                Section("\(Fmt.bytes(group.size)) each · \(group.files.count) copies") {
                                    ForEach(group.files) { file in
                                        HStack(spacing: 10) {
                                            Image(systemName: "doc").foregroundStyle(.secondary)
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(file.url.lastPathComponent).lineLimit(1)
                                                Text(FS.tildePath(file.url)).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                                            }
                                            Spacer()
                                            Button("Reveal") { Finder.reveal([file.url]) }
                                            Button("Move to Trash…") {
                                                if let keep = group.files.first(where: { $0.id != file.id }) { pending = (file, keep) }
                                            }
                                            .disabled(busy || SafetyGuard.check(file.url) != nil || isReadOnly(file.url))
                                        }.padding(.vertical, 3)
                                    }
                                }
                            }
                        }.listStyle(.inset)
                    }
                }
            } else {
                EmptyStateView(symbol: "doc.on.doc", title: "Compare files when you're ready", message: "This separate scan reads matching candidates in full and can take time on large drives.")
            }
        }
        .navigationTitle("Duplicate Finder")
        .alert("Move this copy to Trash?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), presenting: pending) { pair in
            Button("Move to Trash", role: .destructive) { remove(pair.file, keeping: pair.keep) }
            Button("Cancel", role: .cancel) {}
        } message: { pair in
            Text("Prune will compare both files again before moving \(FS.tildePath(pair.file.url)) to Trash. It will keep \(FS.tildePath(pair.keep.url)).")
        }
        .alert("Duplicate Finder", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") { message = nil }
        } message: { Text(message ?? "") }
    }

    private func isReadOnly(_ url: URL) -> Bool {
        model.volumes.contains { $0.readOnly && !$0.isBoot && (url.path == $0.url.path || FS.isAncestor($0.url.path, of: url.path)) }
    }

    private func scan() {
        guard !scanning else { return }
        scanning = true
        status = "Finding files…"
        let settings = model.settings.snapshot
        Task {
            let found = await AppModel.background {
                DuplicateFinder.scan(settings: settings) { text in Task { @MainActor in status = text } }
            }
            report = found
            scanning = false
        }
    }

    private func remove(_ file: DuplicateFinder.File, keeping other: DuplicateFinder.File) {
        busy = true
        Task {
            let result = await AppModel.background { DuplicateFinder.trash(file, keeping: other) }
            if result.0, var current = report {
                for i in current.groups.indices { current.groups[i].files.removeAll { $0.id == file.id } }
                current.groups.removeAll { $0.files.count < 2 }
                report = current
                model.refreshVolumes()
            }
            busy = false
            message = result.1
        }
    }
}
