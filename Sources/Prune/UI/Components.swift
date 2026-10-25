import AppKit
import SwiftUI

extension Risk {
    var color: Color {
        switch self {
        case .safe: .green
        case .low: .blue
        case .review: .orange
        case .high: .red
        }
    }
    var symbol: String {
        switch self {
        case .safe: "checkmark.shield"
        case .low: "arrow.clockwise"
        case .review: "eye"
        case .high: "exclamationmark.triangle"
        }
    }
}

extension Recommendation {
    var color: Color {
        switch self {
        case .recommended: .accentColor
        case .optional: .secondary
        case .keep: .gray
        }
    }
}

struct RiskBadge: View {
    let risk: Risk
    var compact = false
    var body: some View {
        Label(risk.label, systemImage: risk.symbol)
            .labelStyle(.titleAndIcon)
            .font(compact ? .caption2.weight(.medium) : .caption.weight(.medium))
            .foregroundStyle(risk.color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(risk.color.opacity(0.12), in: Capsule())
            .help(risk.blurb)
    }
}

struct VerdictBadge: View {
    let rec: Recommendation
    var body: some View {
        Text(rec.label)
            .font(.caption.weight(.semibold))
            .foregroundStyle(rec == .recommended ? Color.white : rec.color)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background {
                if rec == .recommended { Capsule().fill(Color.accentColor) }
                else { Capsule().strokeBorder(rec.color.opacity(0.5)) }
            }
    }
}

struct DiskBar: View {
    let volume: VolumeInfo
    var height: CGFloat = 10

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let total = max(Double(volume.total), 1)
            let usedW = w * Double(volume.total - volume.available) / total
            let purgeW = w * Double(volume.purgeable) / total
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                HStack(spacing: 0) {
                    Rectangle().fill(barColor).frame(width: max(usedW, 0))
                    Rectangle().fill(barColor.opacity(0.35)).frame(width: max(purgeW, 0))
                }
                .clipShape(Capsule())
            }
        }
        .frame(height: height)
    }

    var freeFraction: Double { Double(volume.available) / max(Double(volume.total), 1) }
    var barColor: Color { freeFraction < 0.05 ? .red : freeFraction < 0.12 ? .orange : .accentColor }
}

struct VolumeCard: View {
    let volume: VolumeInfo
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: volume.isBoot ? "internaldrive.fill" : "externaldrive.fill").foregroundStyle(.secondary)
                Text(volume.name).font(.headline)
                Spacer()
                Text("\(Fmt.bytes(volume.total)) total").font(.caption).foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(Fmt.bytes(volume.available)).font(.system(size: 26, weight: .semibold, design: .rounded))
                    .foregroundStyle(DiskBar(volume: volume).barColor == .accentColor ? Color.primary : DiskBar(volume: volume).barColor)
                Text("available").foregroundStyle(.secondary)
            }
            DiskBar(volume: volume)
            HStack(spacing: 12) {
                legend(DiskBar(volume: volume).barColor, "Used \(Fmt.bytes(volume.total - volume.available))")
                if volume.purgeable > 100_000_000 {
                    legend(DiskBar(volume: volume).barColor.opacity(0.35), "Purgeable \(Fmt.bytes(volume.purgeable))")
                        .help("Space macOS can free on demand (local snapshots, iCloud-optimised files, caches). It's already counted as available.")
                }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }

    private func legend(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 4) { Circle().fill(c).frame(width: 7, height: 7); Text(t) }
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct DetailSection: View {
    let title: String
    let symbol: String
    let text: String
    var tint: Color = .secondary
    var mono = false
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: symbol).font(.caption.weight(.semibold)).foregroundStyle(tint)
            Text(text)
                .font(mono ? .system(.callout, design: .monospaced) : .callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

enum Finder {
    static func reveal(_ urls: [URL]) {
        let existing = urls.filter(FS.exists)
        if existing.isEmpty, let first = urls.first {
            NSWorkspace.shared.open(first.deletingLastPathComponent())
        } else {
            NSWorkspace.shared.activateFileViewerSelecting(existing)
        }
    }
    static func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
    static func chooseFolder(prompt: String = "Choose") -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = prompt
        panel.directoryURL = FS.home
        return panel.runModal() == .OK ? panel.url : nil
    }
}

struct EmptyStateView: View {
    let symbol: String
    let title: String
    let message: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 36)).foregroundStyle(.tertiary)
            Text(title).font(.title3.weight(.semibold))
            Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
