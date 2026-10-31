import SwiftUI

struct AboutView: View {
    @State private var updater = Updater.shared
    @State private var showLicense = false
    @State private var spin = false

    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
                .rotationEffect(.degrees(spin ? 360 : 0))
                .onTapGesture { withAnimation(.spring(duration: 0.9)) { spin.toggle() } }
                .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
            VStack(spacing: 4) {
                Text("Prune").font(.system(size: 28, weight: .bold, design: .rounded))
                Text("Version \(AppInfo.version) (\(AppInfo.build))").font(.callout.monospacedDigit()).foregroundStyle(.secondary).textSelection(.enabled)
                Text("Smart, safe disk cleanup and protection for developers.").font(.callout).foregroundStyle(.secondary)
            }
            updateCard
            HStack(spacing: 14) {
                Link(destination: AppInfo.maintainerURL) { Label("Maintained by \(AppInfo.maintainer)", systemImage: "person.crop.circle") }
                Link(destination: AppInfo.repoURL) { Label("GitHub", systemImage: "chevron.left.forwardslash.chevron.right") }
                Link(destination: AppInfo.repoURL.appendingPathComponent("issues")) { Label("Report an issue", systemImage: "ladybug") }
            }
            .font(.callout)
            VStack(spacing: 6) {
                Button { withAnimation(.snappy) { showLicense.toggle() } } label: {
                    Label("MIT License", systemImage: showLicense ? "chevron.down" : "chevron.right").font(.callout)
                }
                .buttonStyle(.borderless)
                if showLicense {
                    ScrollView {
                        Text(AppInfo.license).font(.system(size: 10, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 180).padding(10)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
                Text("© 2026 alshell7 · Free and open source under the MIT License. Prune works locally and never uploads your files.")
                    .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
        .padding(26)
        .frame(width: 470)
    }

    private var updateCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                statusIcon
                VStack(alignment: .leading, spacing: 2) {
                    Text(statusTitle).font(.headline)
                    Text(statusDetail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                switch updater.state {
                case .available(let r):
                    Button("Update Now") { Task { await updater.install(r) } }.buttonStyle(.borderedProminent)
                case .checking, .downloading, .installing:
                    ProgressView().controlSize(.small)
                default:
                    Button("Check for Updates") { Task { await updater.check() } }
                }
            }
            if case .available(let r) = updater.state, !r.notes.isEmpty {
                ScrollView { Text(r.notes).font(.caption).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }.frame(maxHeight: 90)
            }
            Divider()
            Toggle("Check for updates automatically", isOn: $updater.autoCheck)
            Toggle("Download and install updates automatically", isOn: $updater.autoInstall).disabled(!updater.autoCheck)
        }
        .font(.callout)
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder private var statusIcon: some View {
        let (symbol, tint): (String, Color) = {
            switch updater.state {
            case .available: ("arrow.down.circle.fill", .accentColor)
            case .upToDate: ("checkmark.seal.fill", .green)
            case .failed: ("exclamationmark.triangle.fill", .orange)
            default: ("arrow.triangle.2.circlepath.circle.fill", .secondary)
            }
        }()
        Image(systemName: symbol).font(.title).foregroundStyle(tint)
            .symbolEffect(.pulse, isActive: updater.state == .checking || updater.state == .downloading)
            .contentTransition(.symbolEffect(.replace))
    }

    private var statusTitle: String {
        switch updater.state {
        case .idle: "Updates"
        case .checking: "Checking…"
        case .upToDate: "Prune is up to date"
        case .available(let r): "Version \(r.version) is available"
        case .downloading: "Downloading and verifying…"
        case .installing: "Installing. Prune will reopen."
        case .failed: "Couldn't check for updates"
        }
    }

    private var statusDetail: String {
        switch updater.state {
        case .failed(let m): return m
        case .available(let r): return r.published.map { "Released \(Fmt.ago($0)). Checksum and signature are verified before install." } ?? "Checksum and signature are verified before install."
        default: return updater.lastCheck.map { "Last checked \(Fmt.ago($0))" } ?? "Releases come from github.com/\(AppInfo.repo)."
        }
    }
}
