import AppKit
import SwiftUI

struct ReviewSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var acknowledged = false
    @State private var outcomes: [CleanOutcome]?
    @State private var volumeBefore: Int64 = 0

    private var plan: Cleaner.Plan { Cleaner.dedupe(model.reviewItems) }
    private var items: [CleanupItem] { plan.kept }
    private var runningApps: [NSRunningApplication] {
        let ids = Set(items.compactMap(\.appBundleID))
        return NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier.map(ids.contains) ?? false }
    }
    private var needsAck: Bool { items.contains { $0.risk >= .review } }
    private var permanent: [CleanupItem] {
        items.filter { item in
            if case .emptyTrash = item.action { return true }
            if case .command = item.action { return true }
            if case .removeFiles = item.action { return model.settings.deleteSafeImmediately && item.risk == .safe }
            return false
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let outcomes {
                results(outcomes)
            } else if model.isCleaning {
                progress
            } else {
                review
            }
        }
        .frame(width: 680, height: 600)
        .onAppear { volumeBefore = model.bootVolume?.available ?? 0 }
    }

    // MARK: Review

    private var review: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Review cleanup").font(.title2.weight(.semibold))
                Text("\(items.count) items · \(Fmt.bytes(items.totalSize))" + (plan.skipped.isEmpty ? "" : " · \(plan.skipped.count) nested items already included"))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)

            VStack(alignment: .leading, spacing: 8) {
                let trashed = items.filter { if case .removeFiles = $0.action { return !(model.settings.deleteSafeImmediately && $0.risk == .safe) }; if case .uninstallApp = $0.action { return true }; return false }
                if !trashed.isEmpty {
                    infoRow("trash", .secondary, "\(Fmt.bytes(trashed.totalSize)) will be moved to the Trash. You can put anything back from there. Empty the Trash to actually free the space.")
                }
                if !permanent.isEmpty {
                    infoRow("bolt.fill", .orange, "\(permanent.count) item\(permanent.count == 1 ? "" : "s") (\(Fmt.bytes(permanent.totalSize))) are removed permanently or by their own tool (git, docker, xcrun, brew…). These are caches or things that can be re-downloaded.")
                }
                if items.contains(where: \.needsAdmin) || items.contains(where: { if case .command(let c) = $0.action { return c.needsAdmin }; return false }) {
                    infoRow("lock.fill", .secondary, "Some items are in system locations. macOS will ask for your administrator password once.")
                }
                if !runningApps.isEmpty {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text("Running apps should be quit first: \(runningApps.compactMap(\.localizedName).joined(separator: ", ")).")
                            .font(.callout).fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Quit Them") { runningApps.forEach { $0.terminate() } }
                    }
                }
            }
            .padding(.horizontal, 20)

            List {
                ForEach(Category.allCases) { c in
                    let inCat = items.filter { $0.category == c }
                    if !inCat.isEmpty {
                        Section("\(c.title) · \(Fmt.bytes(inCat.totalSize))") {
                            ForEach(inCat) { item in
                                HStack(spacing: 10) {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(item.title).lineLimit(1).truncationMode(.middle)
                                        Text(item.actionDescription).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                    }
                                    Spacer()
                                    RiskBadge(risk: item.risk, compact: true)
                                    Text(Fmt.bytes(item.size)).monospacedDigit().frame(width: 80, alignment: .trailing)
                                    Button { model.reviewItems.removeAll { $0.id == item.id } } label: { Image(systemName: "xmark.circle.fill") }
                                        .buttonStyle(.borderless).foregroundStyle(.secondary).help("Remove from this cleanup")
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .padding(.top, 10)

            Divider()
            HStack {
                if needsAck {
                    Toggle("I checked the items marked Review or High risk", isOn: $acknowledged).toggleStyle(.checkbox)
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button {
                    Task { outcomes = await model.clean(items) }
                } label: { Text("Clean \(Fmt.bytes(items.totalSize))").frame(minWidth: 120) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(items.isEmpty || (needsAck && !acknowledged))
            }
            .padding(16)
        }
    }

    private func infoRow(_ symbol: String, _ tint: Color, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint).frame(width: 16)
            Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Progress

    private var progress: some View {
        VStack(spacing: 14) {
            Spacer()
            if let p = model.cleanProgress {
                ProgressView(value: Double(p.done), total: Double(max(p.total, 1)))
                    .frame(width: 360)
                Text(p.current).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).frame(width: 420)
            } else {
                ProgressView()
            }
            Spacer()
        }
        .padding()
    }

    // MARK: Results

    private func results(_ outcomes: [CleanOutcome]) -> some View {
        let ok = outcomes.filter { $0.success && $0.method != "Skipped" }
        let failed = outcomes.filter { !$0.success }
        let trashed = ok.filter { $0.method.contains("Trash") || $0.method.hasPrefix("Uninstalled") }
        let freedNow = max(0, (model.bootVolume?.available ?? 0) - volumeBefore)
        return VStack(spacing: 0) {
            VStack(spacing: 8) {
                Image(systemName: failed.isEmpty ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.system(size: 44)).foregroundStyle(failed.isEmpty ? .green : .orange)
                Text(failed.isEmpty ? "Cleanup complete" : "Cleanup finished with \(failed.count) problem\(failed.count == 1 ? "" : "s")").font(.title2.weight(.semibold))
                Text("\(ok.count) items handled · \(Fmt.bytes(ok.reduce(0) { $0 + $1.size })) · \(Fmt.bytes(freedNow)) free space gained so far")
                    .foregroundStyle(.secondary)
                if !trashed.isEmpty {
                    Text("\(Fmt.bytes(trashed.reduce(0) { $0 + $1.size })) is waiting in the Trash. Empty it to reclaim the space, or restore anything you still need.")
                        .font(.callout).multilineTextAlignment(.center).frame(maxWidth: 480).padding(.top, 4)
                }
            }
            .padding(24)
            List {
                if !failed.isEmpty {
                    Section("Problems") {
                        ForEach(failed) { o in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(o.title).fontWeight(.medium)
                                Text(o.message.isEmpty ? "Failed" : o.message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }
                    }
                }
                Section("Done") {
                    ForEach(ok) { o in
                        HStack {
                            Image(systemName: "checkmark").foregroundStyle(.green)
                            Text(o.title).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(o.method).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            Text(Fmt.bytes(o.size)).monospacedDigit().frame(width: 80, alignment: .trailing)
                        }
                    }
                }
            }
            .listStyle(.inset)
            Divider()
            HStack {
                Button("Open Trash") { NSWorkspace.shared.open(FS.home.appendingPathComponent(".Trash")) }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
    }
}
