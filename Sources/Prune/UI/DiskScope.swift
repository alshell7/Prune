import SwiftUI

/// "All disks · Macintosh HD · Work HD": focuses cleanup, Code Backup, Secrets and Doctor on one disk.
struct DiskScopeBar: View {
    @Environment(AppModel.self) private var model
    var counts: ((VolumeInfo?) -> String?)? = nil

    private var disks: [VolumeInfo] {
        model.volumes.filter { $0.isBoot || (model.settings.includeExternalVolumes && !model.settings.excludedVolumes.contains($0.url.path)) }
    }

    var body: some View {
        if disks.count > 1 {
            HStack(spacing: 6) {
                chip(nil, symbol: "square.stack.3d.up.fill", title: "All disks")
                ForEach(disks) { v in
                    chip(v, symbol: v.isBoot ? "internaldrive.fill" : "externaldrive.fill", title: v.name)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func chip(_ v: VolumeInfo?, symbol: String, title: String) -> some View {
        let selected = model.diskScope == v?.url.path
        let detail = counts?(v) ?? v.map { "\(Fmt.bytes($0.available)) free" }
        return Button {
            withAnimation(.snappy) { model.diskScope = v?.url.path }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.caption)
                Text(title).font(.callout.weight(selected ? .semibold : .regular)).lineLimit(1)
                if let detail { Text(detail).font(.caption2.monospacedDigit()).foregroundStyle(selected ? .white.opacity(0.85) : .secondary) }
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .foregroundStyle(selected ? .white : .primary)
            .background(Capsule().fill(selected ? Color.accentColor : Color.primary.opacity(0.06)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(v.map { "Show only \($0.name)" } ?? "Show every analyzed disk")
    }
}

/// Small tag naming the disk a path lives on, shown for anything not on the startup disk.
struct VolumeBadge: View {
    @Environment(AppModel.self) private var model
    let url: URL

    var body: some View {
        if let v = model.volume(for: url), !v.isBoot {
            Label(v.name, systemImage: "externaldrive.fill")
                .labelStyle(.titleAndIcon)
                .font(.caption2.weight(.medium)).foregroundStyle(.teal)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Color.teal.opacity(0.12), in: Capsule())
                .lineLimit(1).fixedSize()
        }
    }
}

/// Bottom toast shared by the module views.
struct ToastView: View {
    let ok: Bool
    let text: String
    var body: some View {
        Label(text, systemImage: ok ? "checkmark.circle.fill" : "xmark.octagon.fill").lineLimit(3)
            .symbolRenderingMode(.multicolor)
            .padding(.horizontal, 14).padding(.vertical, 10).frame(maxWidth: 560)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
            .padding(.bottom, 16).transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

/// Scale-on-press for prominent actions.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}
