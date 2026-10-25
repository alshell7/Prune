import SwiftUI

// MARK: - Disk ring

/// Donut of the disk: what's used, what Prune can give back, what macOS can purge, what's free.
struct DiskRing: View {
    let volume: VolumeInfo
    var reclaimable: Int64 = 0
    var optional: Int64 = 0
    var lineWidth: CGFloat = 14
    var highlight: Segment? = nil
    @State private var progress: CGFloat = 0

    enum Segment: String, CaseIterable { case used = "In use", recommended = "Prune recommends", optional = "Optional cleanup", purgeable = "Purgeable by macOS", free = "Free" }

    struct Slice { var segment: Segment; var start: CGFloat; var end: CGFloat; var color: Color }

    static func color(_ s: Segment, fullness: Double) -> Color {
        switch s {
        case .used: fullness > 0.95 ? .red : (fullness > 0.88 ? .orange : .indigo)
        case .recommended: .green
        case .optional: .mint
        case .purgeable: .gray.opacity(0.6)
        case .free: .primary.opacity(0.08)
        }
    }

    var slices: [Slice] {
        let total = max(Double(volume.total), 1)
        let rec = min(Double(reclaimable), Double(volume.used))
        let opt = min(Double(optional), Double(volume.used) - rec)
        let used = Double(volume.used) - rec - opt
        let purge = Double(volume.purgeable)
        let parts: [(Segment, Double)] = [(.used, used), (.recommended, rec), (.optional, opt), (.purgeable, purge)]
        var start: CGFloat = 0
        var out: [Slice] = []
        for (seg, v) in parts where v > 0 {
            let len = CGFloat(v / total)
            out.append(Slice(segment: seg, start: start, end: start + len, color: Self.color(seg, fullness: volume.usedFraction)))
            start += len
        }
        return out
    }

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.08), lineWidth: lineWidth)
            ForEach(slices, id: \.segment) { s in
                Circle()
                    .trim(from: s.start * progress, to: max(s.start * progress, s.end * progress - 0.002))
                    .stroke(s.color, style: StrokeStyle(lineWidth: highlight == s.segment ? lineWidth * 1.35 : lineWidth, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
                    .opacity(highlight == nil || highlight == s.segment ? 1 : 0.35)
            }
        }
        .animation(.snappy, value: highlight)
        .onAppear { withAnimation(.spring(duration: 1.1, bounce: 0.15)) { progress = 1 } }
    }
}

/// The Overview hero: a big ring with an interactive legend.
struct DiskHero: View {
    let volume: VolumeInfo
    let recommended: Int64
    let optional: Int64
    @State private var hovered: DiskRing.Segment?

    var body: some View {
        HStack(spacing: 28) {
            ZStack {
                DiskRing(volume: volume, reclaimable: recommended, optional: optional, lineWidth: 22, highlight: hovered)
                    .frame(width: 190, height: 190)
                VStack(spacing: 2) {
                    Text(Fmt.bytes(volume.available)).font(.system(size: 30, weight: .bold, design: .rounded)).contentTransition(.numericText())
                        .foregroundStyle(volume.usedFraction > 0.95 ? .red : .primary)
                    Text("free of \(Fmt.bytes(volume.total))").font(.caption).foregroundStyle(.secondary)
                    if recommended > 0 {
                        Text("\u{2192} \(Fmt.bytes(volume.available + recommended)) after cleanup").font(.caption2.weight(.semibold)).foregroundStyle(.green)
                            .padding(.top, 4)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                Text(volume.name).font(.headline)
                legend(.used, Int64(volume.used) - recommended - optional, "Apps, projects, data and the system")
                legend(.recommended, recommended, "Safe to remove now")
                legend(.optional, optional, "Your call (active projects, models…)")
                if volume.purgeable > 100_000_000 { legend(.purgeable, volume.purgeable, "macOS frees this on its own when needed") }
                legend(.free, volume.availableStrict, "Available right now")
            }
        }
    }

    private func legend(_ s: DiskRing.Segment, _ value: Int64, _ hint: String) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 3).fill(s == .free ? Color.primary.opacity(0.2) : DiskRing.color(s, fullness: volume.usedFraction)).frame(width: 12, height: 12)
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(s.rawValue).font(.callout.weight(.medium))
                    Text(Fmt.bytes(max(0, value))).font(.callout.monospacedDigit()).foregroundStyle(.secondary).contentTransition(.numericText())
                }
                Text(hint).font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 6).fill(hovered == s ? Color.primary.opacity(0.06) : .clear))
        .onHover { h in withAnimation(.snappy(duration: 0.15)) { hovered = h ? s : nil } }
    }
}

// MARK: - Stacked bar

struct BarSegment: Identifiable, Hashable {
    var id: String { label }
    var label: String
    var value: Int64
    var color: Color
}

/// A single bar split into proportional, hoverable segments.
struct StackedBar: View {
    let segments: [BarSegment]
    var height: CGFloat = 26
    var onTap: ((BarSegment) -> Void)? = nil
    @State private var grow = false
    @State private var hover: String?

    var body: some View {
        let total = max(1, segments.reduce(0) { $0 + $1.value })
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { g in
                HStack(spacing: 2) {
                    ForEach(segments.filter { $0.value > 0 }) { s in
                        let w = max(4, (g.size.width - CGFloat(segments.count * 2)) * CGFloat(s.value) / CGFloat(total))
                        RoundedRectangle(cornerRadius: 5).fill(s.color.gradient)
                            .frame(width: grow ? w : 4)
                            .overlay {
                                if w > 70 { Text(Fmt.bytes(s.value)).font(.caption2.weight(.bold)).foregroundStyle(.white).lineLimit(1).padding(.horizontal, 4) }
                            }
                            .opacity(hover == nil || hover == s.id ? 1 : 0.4)
                            .onHover { h in withAnimation(.snappy(duration: 0.15)) { hover = h ? s.id : nil } }
                            .onTapGesture { onTap?(s) }
                            .help("\(s.label): \(Fmt.bytes(s.value))")
                    }
                }
            }
            .frame(height: height)
            FlowLegend(segments: segments.filter { $0.value > 0 }, hover: $hover)
        }
        .onAppear { withAnimation(.spring(duration: 0.9, bounce: 0.2)) { grow = true } }
    }
}

struct FlowLegend: View {
    let segments: [BarSegment]
    @Binding var hover: String?
    var body: some View {
        // Wraps legend chips across lines.
        WrapLayout(spacing: 12, lineSpacing: 6) {
            ForEach(segments) { s in
                HStack(spacing: 5) {
                    Circle().fill(s.color).frame(width: 8, height: 8)
                    Text("\(s.label) \(Fmt.bytes(s.value))").font(.caption).foregroundStyle(hover == nil || hover == s.id ? .primary : .secondary)
                }
                .onHover { h in withAnimation(.snappy(duration: 0.15)) { hover = h ? s.id : nil } }
            }
        }
    }
}

struct WrapLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        var x: CGFloat = 0, y: CGFloat = 0, lineH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > width && x > 0 { x = 0; y += lineH + lineSpacing; lineH = 0 }
            x += s.width + spacing; lineH = max(lineH, s.height)
        }
        return CGSize(width: width, height: y + lineH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX && x > bounds.minX { x = bounds.minX; y += lineH + lineSpacing; lineH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing; lineH = max(lineH, s.height)
        }
    }
}

// MARK: - Inline size bar for tables

struct SizeCell: View {
    let size: Int64
    let max: Int64
    var estimate = false
    var body: some View {
        HStack(spacing: 6) {
            GeometryReader { g in
                Capsule().fill(Color.accentColor.opacity(0.18))
                    .overlay(alignment: .leading) {
                        Capsule().fill(Color.accentColor.opacity(0.75)).frame(width: g.size.width * CGFloat(Double(size) / Double(Swift.max(max, 1))))
                    }
            }
            .frame(width: 34, height: 5)
            Text((estimate ? "≈ " : "") + Fmt.bytes(size)).monospacedDigit().frame(minWidth: 56, alignment: .trailing)
        }
    }
}

// MARK: - Treemap

enum Squarify {
    /// Squarified treemap layout (Bruls, Huizing & van Wijk). Values must be sorted descending.
    static func layout(_ values: [Double], in rect: CGRect) -> [CGRect] {
        var rects = [CGRect](repeating: .zero, count: values.count)
        let total = values.reduce(0, +)
        guard total > 0, rect.width > 1, rect.height > 1 else { return rects }
        let scaled = values.map { $0 / total * Double(rect.width * rect.height) }
        var remaining = rect
        var i = 0
        func worst(_ row: [Double], _ side: Double) -> Double {
            let s = row.reduce(0, +)
            guard s > 0, side > 0 else { return .infinity }
            return row.map { Swift.max(side * side * $0 / (s * s), (s * s) / (side * side * $0)) }.max() ?? .infinity
        }
        while i < scaled.count {
            let side = Double(min(remaining.width, remaining.height))
            var row = [scaled[i]]
            var j = i + 1
            while j < scaled.count, worst(row + [scaled[j]], side) <= worst(row, side) { row.append(scaled[j]); j += 1 }
            let sum = row.reduce(0, +)
            if remaining.width >= remaining.height {
                let w = CGFloat(sum / Double(remaining.height))
                var y = remaining.minY
                for k in i..<j { let h = CGFloat(scaled[k]) / w; rects[k] = CGRect(x: remaining.minX, y: y, width: w, height: h); y += h }
                remaining = CGRect(x: remaining.minX + w, y: remaining.minY, width: remaining.width - w, height: remaining.height)
            } else {
                let h = CGFloat(sum / Double(remaining.width))
                var x = remaining.minX
                for k in i..<j { let w = CGFloat(scaled[k]) / h; rects[k] = CGRect(x: x, y: remaining.minY, width: w, height: h); x += w }
                remaining = CGRect(x: remaining.minX, y: remaining.minY + h, width: remaining.width, height: remaining.height - h)
            }
            i = j
        }
        return rects
    }
}

struct TreemapView: View {
    let entries: [ExplorerModel.Entry]
    let onOpen: (ExplorerModel.Entry) -> Void
    let onSelect: (ExplorerModel.Entry) -> Void
    @State private var hover: String?

    enum Kind: String, CaseIterable { case folder = "Folders", rebuildable = "Rebuildable (caches, builds, node_modules)", hidden = "Hidden / tool data", media = "Media", archive = "Archives & disk images", file = "Other files" }

    static func kind(_ e: ExplorerModel.Entry) -> Kind {
        let n = e.name.lowercased()
        if ArtifactRules.allNames.contains(e.name) || ["caches", "cache", ".cache", "deriveddata", "build", "dist", "target"].contains(n) { return .rebuildable }
        if n.hasPrefix(".") { return .hidden }
        let ext = e.url.pathExtension.lowercased()
        if ["mov", "mp4", "mkv", "avi", "m4v", "jpg", "jpeg", "png", "heic", "gif", "mp3", "wav", "aiff", "m4a", "psd", "raw", "dng"].contains(ext) { return .media }
        if ["zip", "tar", "gz", "tgz", "dmg", "iso", "pkg", "xip", "7z", "rar", "img", "raw", "vmdk", "qcow2", "ipsw"].contains(ext) { return .archive }
        return e.isDir ? .folder : .file
    }

    static func color(_ k: Kind, name: String) -> Color {
        switch k {
        case .folder:
            let hue = Double(abs(name.hashValue % 1000)) / 1000.0 * 0.18 + 0.52   // blues → teals
            return Color(hue: hue, saturation: 0.55, brightness: 0.78)
        case .rebuildable: return .orange
        case .hidden: return .purple.opacity(0.75)
        case .media: return .pink
        case .archive: return .brown
        case .file: return .gray
        }
    }

    var body: some View {
        GeometryReader { g in
            let items = entries.filter { ($0.size ?? 0) > 0 }.sorted { ($0.size ?? 0) > ($1.size ?? 0) }.prefix(160)
            let rects = Squarify.layout(items.map { Double($0.size ?? 0) }, in: CGRect(origin: .zero, size: g.size))
            ZStack(alignment: .topLeading) {
                ForEach(Array(items.enumerated()), id: \.element.id) { i, e in
                    let r = rects[i].insetBy(dx: 1.5, dy: 1.5)
                    let k = Self.kind(e)
                    let hovered = hover == e.id
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Self.color(k, name: e.name).gradient)
                        .brightness(hovered ? 0.12 : 0)
                        .overlay(alignment: .topLeading) {
                            if r.width > 70 && r.height > 34 {
                                VStack(alignment: .leading, spacing: 1) {
                                    HStack(spacing: 4) {
                                        if e.isDir { Image(systemName: "folder.fill").font(.caption2) }
                                        Text(e.name).font(.caption.weight(.semibold)).lineLimit(1)
                                    }
                                    Text(Fmt.bytes(e.size ?? 0)).font(.caption2.monospacedDigit()).opacity(0.85)
                                }
                                .foregroundStyle(.white)
                                .padding(6)
                            }
                        }
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(hovered ? 0.9 : 0), lineWidth: 2))
                        .frame(width: max(0, r.width), height: max(0, r.height))
                        .offset(x: r.minX, y: r.minY)
                        .onHover { h in hover = h ? e.id : (hover == e.id ? nil : hover) }
                        .onTapGesture(count: 2) { onOpen(e) }
                        .onTapGesture { onSelect(e) }
                        .help("\(e.name) · \(Fmt.bytes(e.size ?? 0))" + (e.isDir ? " · double-click to open" : ""))
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .animation(.spring(duration: 0.45, bounce: 0.12), value: items.map { "\($0.id)\($0.size ?? 0)" })
        }
    }
}

// MARK: - Before / after for Offload

struct BeforeAfterBar: View {
    let title: String
    let icon: String
    let total: Int64
    let usedNow: Int64
    let usedAfter: Int64
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(title, systemImage: icon).font(.caption.weight(.semibold))
                Spacer()
                Text("\(Fmt.bytes(max(0, total - usedNow))) \u{2192} \(Fmt.bytes(max(0, total - usedAfter))) free").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            GeometryReader { g in
                let w = g.size.width
                let now = CGFloat(Double(usedNow) / Double(max(total, 1))) * w
                let after = CGFloat(Double(usedAfter) / Double(max(total, 1))) * w
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule().fill(Color.accentColor.opacity(0.35)).frame(width: max(now, after))
                    Capsule().fill(usedAfter > usedNow ? Color.orange : Color.accentColor).frame(width: min(now, after))
                    if usedAfter < usedNow {
                        Rectangle().fill(Color.green.opacity(0.85)).frame(width: max(0, now - after)).offset(x: after)
                            .mask(Capsule().frame(width: now))
                    }
                }
                .animation(.spring(duration: 0.5), value: usedAfter)
            }
            .frame(height: 8)
        }
    }
}


// MARK: - Micro-interactions

struct HoverLift: ViewModifier {
    @State private var hover = false
    func body(content: Content) -> some View {
        content
            .scaleEffect(hover ? 1.02 : 1)
            .shadow(color: .black.opacity(hover ? 0.10 : 0), radius: hover ? 8 : 0, y: hover ? 3 : 0)
            .onHover { h in withAnimation(.snappy(duration: 0.18)) { hover = h } }
    }
}

extension View {
    func hoverLift() -> some View { modifier(HoverLift()) }
}

struct StatusTile: View {
    let icon: String
    let tint: Color
    let title: String
    let value: String
    let detail: String
    var busy = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 26)).foregroundStyle(tint)
                    .symbolEffect(.pulse, isActive: busy)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(value).font(.headline).contentTransition(.numericText())
                    if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(tint.opacity(0.25)))
            .contentShape(Rectangle())
            .hoverLift()
        }
        .buttonStyle(.plain)
    }
}


// MARK: - Disks

/// Every mounted disk with its own ring and an "Analyze" switch that controls what scans cover.
struct DisksSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Disks").font(.title3.weight(.semibold))
                Text("\(model.volumes.count) mounted").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { model.refreshVolumes() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless).help("Refresh disks")
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 12)], spacing: 12) {
                ForEach(model.volumes) { v in DiskTile(volume: v) }
            }
            if model.volumes.count == 1 {
                Text("Connect an external drive and it appears here. Turn on \u{201C}Analyze\u{201D} to include it in scans (projects, build artifacts, large files, Trash) or use it as an Offload destination.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct DiskTile: View {
    @Environment(AppModel.self) private var model
    let volume: VolumeInfo

    private var analyzed: Bool {
        volume.isBoot || (model.settings.includeExternalVolumes && !model.settings.excludedVolumes.contains(volume.url.path))
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                DiskRing(volume: volume, lineWidth: 7).frame(width: 52, height: 52)
                Image(systemName: volume.isBoot ? "internaldrive.fill" : (volume.isInternal ? "internaldrive" : "externaldrive.fill"))
                    .font(.system(size: 15)).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(volume.name).font(.headline).lineLimit(1)
                    if !volume.format.isEmpty { Text(volume.format).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        .padding(.horizontal, 5).padding(.vertical, 1).background(Color.secondary.opacity(0.12), in: Capsule()) }
                }
                Text("\(Fmt.bytes(volume.available)) free of \(Fmt.bytes(volume.total))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    if volume.isBoot {
                        Label("Always analyzed", systemImage: "checkmark.circle.fill").font(.caption2).foregroundStyle(.green)
                    } else if volume.readOnly {
                        Label("Read-only", systemImage: "lock").font(.caption2).foregroundStyle(.secondary)
                    } else {
                        Toggle("Analyze", isOn: Binding(get: { analyzed }, set: { on in
                            if on {
                                model.settings.includeExternalVolumes = true
                                model.settings.excludedVolumes.removeAll { $0 == volume.url.path }
                            } else if !model.settings.excludedVolumes.contains(volume.url.path) {
                                model.settings.excludedVolumes.append(volume.url.path)
                            }
                        }))
                        .toggleStyle(.switch).controlSize(.mini).font(.caption2)
                    }
                    Button("Explore") { model.showInExplorer(volume.url) }.buttonStyle(.link).font(.caption2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(analyzed ? Color.accentColor.opacity(0.35) : .clear))
        .hoverLift()
    }
}
