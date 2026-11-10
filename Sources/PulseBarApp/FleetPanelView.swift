import AppKit
import SwiftUI

/// Fleet panel modelled on patcastle/omarchy-sparkdash: totals on top, 24 h energy, exceptions, then one card per host.
private enum Palette {
    static let background = Color(red: 0.08, green: 0.09, blue: 0.11)
    static let foreground = Color(white: 0.93)
    static let dim = Color(white: 0.62)
    static let faint = Color(white: 0.45)
    static let fill = Color.white.opacity(0.04)
    static let stroke = Color.white.opacity(0.14)
    static let healthy = Color(red: 0.35, green: 0.79, blue: 0.60)
    static let amber = Color(red: 0.95, green: 0.72, blue: 0.29)
    static let urgent = Color(red: 0.90, green: 0.33, blue: 0.30)
}

private func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
    .system(size: size, weight: weight, design: .monospaced)
}

enum FleetFormat {
    static func number(_ value: Double, _ digits: Int = 1) -> String { String(format: "%.\(digits)f", value) }
    static func gb(_ mb: Double) -> String { number(mb / 1024) }
    static func tps(_ value: Double) -> String { value >= 100 ? "\(Int(value.rounded()))" : number(value) }
    static func pct(_ value: Double?) -> String { value.map { "\(number($0 * 100))%" } ?? "—" }
    static func secs(_ value: Double?) -> String {
        guard let value else { return "—" }
        return value < 1 ? "\(Int((value * 1000).rounded()))ms" : "\(number(value, value < 10 ? 2 : 1))s"
    }
    static func uptime(_ seconds: Double?) -> String {
        guard let seconds else { return "—" }
        let s = Int(seconds)
        let d = s / 86_400
        let h = (s % 86_400) / 3_600
        let m = (s % 3_600) / 60
        return d > 0 ? "\(d)d \(h)h" : h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }
    static func rate(_ bytes: Double) -> String {
        switch bytes {
        case 1_073_741_824...: return "\(number(bytes / 1_073_741_824)) GB/s"
        case 1_048_576...: return "\(number(bytes / 1_048_576)) MB/s"
        case 1_024...: return "\(number(bytes / 1_024)) KB/s"
        default: return "\(Int(bytes)) B/s"
        }
    }
    static func grouped(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? "\(Int(value))"
    }
}

@MainActor
struct FleetPanelView: View {
    @ObservedObject var model: FleetViewModel
    @State private var expandedID: String?
    @State private var showSettings = false
    @State private var contentHeight: CGFloat = 520

    /// `scrolls: false` lays the panel out flat, for ImageRenderer (which cannot draw ScrollView contents).
    private let scrolls: Bool

    init(model: FleetViewModel, initiallyExpanded: String? = nil, scrolls: Bool = true) {
        self.model = model
        self.scrolls = scrolls
        _expandedID = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        Group {
            if scrolls {
                // A MenuBarExtra window sizes to the ScrollView's ideal height, which is ~0, so measure the content and
                // set the height explicitly, capped to the screen.
                ScrollView {
                    content.background(
                        GeometryReader { geo in Color.clear.preference(key: ContentHeightKey.self, value: geo.size.height) })
                }
                .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0 }
                .frame(height: min(contentHeight, maxPanelHeight))
            } else {
                content
            }
        }
        .frame(width: 400)
        .background(Palette.background)
        .environment(\.colorScheme, .dark)
    }

    private var maxPanelHeight: CGFloat {
        ((NSScreen.main?.visibleFrame.height ?? 900) - 40).rounded()
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if model.reachable {
                totals
                tiles
                if let energy = model.snapshot.energy, !energy.hourlyWatts.isEmpty { energyChart(energy) }
                alerts
                ForEach(model.snapshot.sparks) { spark in
                    SparkCard(
                        spark: spark, history: model.history[spark.id] ?? [], expanded: expandedID == spark.id
                    ) {
                        withAnimation(.easeInOut(duration: 0.15)) { expandedID = expandedID == spark.id ? nil : spark.id }
                    }
                }
            } else {
                Text(model.errorText)
                    .font(mono(12))
                    .foregroundStyle(Palette.urgent)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Palette.urgent.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
            }
            if showSettings { settings }
            footer
        }
        .padding(16)
    }

    private var header: some View {
        HStack {
            Text("DGX SPARKS").font(mono(15, .bold)).tracking(1.2).foregroundStyle(Palette.foreground)
            Spacer()
            Text(model.reachable ? "\(model.snapshot.onlineCount)/\(model.snapshot.totalCount) ONLINE" : "OFFLINE")
                .font(mono(12, .bold))
                .foregroundStyle(
                    model.reachable && model.snapshot.onlineCount == model.snapshot.totalCount ? Palette.healthy : Palette.urgent)
        }
    }

    private var totals: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(FleetFormat.tps(model.snapshot.generationTps)) tok/s")
                .font(mono(34, .bold))
                .foregroundStyle(Palette.foreground)
                .contentTransition(.numericText())
            Text("GENERATION  ·  PREFILL \(FleetFormat.tps(model.snapshot.prefillTps))")
                .font(mono(11, .bold)).tracking(1).foregroundStyle(Palette.dim)
        }
    }

    private var tiles: some View {
        let s = model.snapshot
        let vramPct = s.vramTotalMB > 0 ? s.vramUsedMB / s.vramTotalMB * 100 : 0
        let memPct = s.memTotalMB > 0 ? s.memUsedMB / s.memTotalMB * 100 : 0
        return HStack(spacing: 8) {
            Tile(value: "\(Int(s.watts.rounded())) W", label: "POWER", detail: "")
            Tile(
                value: "\(Int(vramPct.rounded()))%", label: "VRAM",
                detail: "\(FleetFormat.gb(s.vramUsedMB)) / \(FleetFormat.gb(s.vramTotalMB))")
            Tile(
                value: "\(Int(memPct.rounded()))%", label: "MEMORY",
                detail: "\(FleetFormat.gb(s.memUsedMB)) / \(FleetFormat.gb(s.memTotalMB))")
            Tile(
                value: s.energy?.energy24hKwh.map { FleetFormat.number($0, 2) } ?? "—", label: "kWh · 24H",
                detail: s.energy?.whPerOutputToken24h.map { "\(FleetFormat.number($0, 4)) Wh/tok" } ?? "")
        }
    }

    private func energyChart(_ energy: FleetEnergy) -> some View {
        let values = energy.hourlyWatts.map { $0 ?? 0 }
        let peak = max(values.max() ?? 1, 1)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("FLEET ENERGY · 24H").font(mono(11, .bold)).tracking(1).foregroundStyle(Palette.dim)
                Spacer()
                Text("\(energy.freshNodeCount)/\(energy.nodeCount) fresh").font(mono(11)).foregroundStyle(Palette.faint)
            }
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(Array(energy.hourlyWatts.enumerated()), id: \.offset) { _, watts in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(watts == nil ? Palette.stroke : Palette.dim.opacity(0.8))
                        .frame(height: max(2, 44 * (watts ?? 0) / peak))
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 44, alignment: .bottom)
        }
    }

    @ViewBuilder private var alerts: some View {
        ForEach(model.snapshot.alerts, id: \.self) { alert in
            let tint = alert.severity == .critical ? Palette.urgent : Palette.amber
            HStack {
                Text(alert.host).font(mono(11, .bold))
                Spacer()
                Text(alert.label).font(mono(11))
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(tint.opacity(0.4)))
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SPARKDASH").font(mono(11, .bold)).tracking(1).foregroundStyle(Palette.dim)
            LabeledField(label: "URL", text: $model.urlString, prompt: FleetSettings.defaultURL)
            LabeledField(label: "SSH host", text: $model.sshHost, prompt: "optional, e.g. spark-head")
            Text(
                "With an SSH host, PulseBar runs `ssh -N -L <free port>:127.0.0.1:<URL port>` to that host "
                    + "and reads sparkDash through it, for a dashboard bound to loopback on the Spark."
            )
            .font(.system(size: 10)).foregroundStyle(Palette.faint)
        }
        .padding(10)
        .background(Palette.fill, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Palette.stroke))
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Button("Open sparkDash") { model.openDashboard() }
            Button {
                showSettings.toggle()
            } label: {
                Image(systemName: "gearshape")
            }.help("sparkDash connection")
            Spacer()
            if let last = model.lastUpdate, model.reachable {
                Text(last, style: .relative).font(mono(10)).foregroundStyle(Palette.faint)
            }
            Button {
                model.quit()
            } label: {
                Image(systemName: "power")
            }.help("Quit")
        }
        .buttonStyle(.plain)
        .font(mono(11, .bold))
        .foregroundStyle(Palette.dim)
    }
}

private struct LabeledField: View {
    let label: String
    @Binding var text: String
    let prompt: String
    @State private var draft = ""

    var body: some View {
        HStack {
            Text(label).font(mono(11)).foregroundStyle(Palette.dim).frame(width: 70, alignment: .leading)
            TextField(prompt, text: $draft)
                .textFieldStyle(.roundedBorder)
                .font(mono(11))
                .onSubmit { text = draft }
                .onAppear { draft = text }
        }
    }
}

private struct Tile: View {
    let value: String
    let label: String
    let detail: String

    var body: some View {
        VStack(spacing: 3) {
            Text(value).font(mono(13, .bold)).foregroundStyle(Palette.foreground)
            Text(label).font(mono(9, .bold)).foregroundStyle(Palette.dim)
            if !detail.isEmpty { Text(detail).font(mono(9)).foregroundStyle(Palette.faint) }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .frame(maxWidth: .infinity, minHeight: 64)
        .background(Palette.fill)
        .overlay(Rectangle().stroke(Palette.stroke))
    }
}

private struct Bar: View {
    let label: String
    let value: String
    let fraction: Double
    var tint: Color = Palette.healthy

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text(label).foregroundStyle(Palette.dim)
                Spacer()
                Text(value).bold().foregroundStyle(Palette.foreground)
            }
            .font(mono(11))
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.foreground.opacity(0.14))
                    Capsule().fill(tint).frame(width: geo.size.width * min(max(fraction, 0), 1))
                }
            }
            .frame(height: 4)
        }
    }
}

private struct Pair: View {
    let label: String
    let value: String
    var warn = false

    var body: some View {
        HStack {
            Text(label).foregroundStyle(Palette.dim)
            Spacer(minLength: 4)
            Text(value).bold().foregroundStyle(warn ? Palette.amber : Palette.foreground)
        }
        .font(mono(11))
        .lineLimit(1)
    }
}

private struct Sparkline: View {
    let values: [Double]

    var body: some View {
        GeometryReader { geo in
            let peak = max(values.max() ?? 1, 1)
            Path { path in
                guard values.count > 1 else { return }
                let step = geo.size.width / CGFloat(values.count - 1)
                for (index, value) in values.enumerated() {
                    let point = CGPoint(x: CGFloat(index) * step, y: geo.size.height * (1 - CGFloat(value / peak)))
                    index == 0 ? path.move(to: point) : path.addLine(to: point)
                }
            }
            .stroke(Palette.amber, lineWidth: 1.5)
        }
    }
}

private struct SparkCard: View {
    let spark: SparkSummary
    let history: [Double]
    let expanded: Bool
    let toggle: () -> Void

    private var status: Color {
        !spark.online ? Palette.urgent : (spark.throttled || spark.temperature >= 85 ? Palette.amber : Palette.healthy)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: toggle) {
                HStack(spacing: 6) {
                    Circle().fill(status).frame(width: 7, height: 7)
                    Text(spark.name).font(mono(12, .bold)).foregroundStyle(Palette.foreground).lineLimit(1).layoutPriority(1)
                    Text(spark.roleLabel)
                        .font(mono(9, .bold)).foregroundStyle(Palette.dim).lineLimit(1)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .overlay(Rectangle().stroke(Palette.stroke))
                    Spacer(minLength: 4)
                    if spark.llmMonitoring {
                        Text("\(FleetFormat.tps(spark.generationTps)) tok/s").font(mono(12, .bold)).foregroundStyle(Palette.foreground)
                    } else {
                        Text(spark.online ? "ONLINE" : "OFFLINE").font(mono(10, .bold)).foregroundStyle(status)
                    }
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 9)).foregroundStyle(Palette.faint)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Text(
                ["up \(FleetFormat.uptime(spark.uptime))", spark.gpuChip, spark.backend.uppercased()]
                    .filter { !$0.isEmpty }.joined(separator: " · ")
            )
            .font(mono(10)).foregroundStyle(Palette.faint)

            HStack(alignment: .top, spacing: 12) {
                VStack(spacing: 4) {
                    Pair(label: "Usage", value: "\(Int(spark.usage.rounded()))%", warn: spark.usage >= 90)
                    Pair(label: "Temperature", value: "\(Int(spark.temperature.rounded()))°C", warn: spark.temperature >= 85)
                    Pair(label: "VRAM", value: "\(FleetFormat.gb(spark.vramUsedMB)) / \(FleetFormat.gb(spark.vramTotalMB)) GB")
                    Pair(label: "Power", value: "\(FleetFormat.number(spark.power)) / \(Int(spark.powerLimit)) W")
                }
                if spark.llmMonitoring {
                    Sparkline(values: history).frame(width: 110, height: 56)
                }
            }

            if !spark.model.isEmpty {
                Text(spark.model).font(mono(11, .bold)).foregroundStyle(spark.llmAvailable ? Palette.amber : Palette.dim).lineLimit(1)
            }

            if expanded { detail }
        }
        .padding(10)
        .background(Palette.fill)
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Palette.stroke))
    }

    @ViewBuilder private var detail: some View {
        Divider().overlay(Palette.stroke)
        let memTint = spark.oomRisk == "high" ? Palette.urgent : spark.oomRisk == "medium" ? Palette.amber : Palette.healthy
        Bar(
            label: "Unified memory",
            value: "\(FleetFormat.gb(spark.memUsedMB)) / \(FleetFormat.gb(spark.memTotalMB)) GB · \(spark.oomRisk)",
            fraction: spark.memTotalMB > 0 ? spark.memUsedMB / spark.memTotalMB : 0, tint: memTint)
        Bar(
            label: "Storage · \(spark.storageLabel)", value: "\(Int(spark.storagePct.rounded()))%", fraction: spark.storagePct / 100,
            tint: spark.storagePct >= 90 ? Palette.amber : Palette.healthy)
        if let clock = spark.smClockMHz, let peak = spark.smClockMaxMHz, peak > 0 {
            Bar(
                label: "SM clock · \(spark.throttleReason)", value: "\(Int(clock)) / \(Int(peak)) MHz", fraction: clock / peak,
                tint: Palette.dim)
        }
        Grid(horizontalSpacing: 16, verticalSpacing: 4) {
            GridRow {
                Pair(label: "CPU", value: "\(Int(spark.cpuUsage.rounded()))% · \(Int(spark.cpuTemp.rounded()))°C")
                Pair(label: "Network", value: spark.netPrimary)
            }
            GridRow {
                Pair(label: "CPU power", value: "\(Int(spark.cpuPower.rounded())) / \(Int(spark.cpuTdp)) W")
                Pair(label: "Link", value: spark.netLinkMbps.map { "\(Int($0)) Mbps" } ?? "—")
            }
            GridRow {
                Pair(label: "Mem BW", value: "\(Int(spark.memBandwidth)) / \(Int(spark.memBandwidthPeak)) GB/s")
                Pair(label: "↓↑", value: "\(FleetFormat.rate(spark.netRx)) \(FleetFormat.rate(spark.netTx))")
            }
        }
        if !spark.topProcess.isEmpty {
            Pair(label: "Top process", value: "\(spark.topProcess) · \(FleetFormat.gb(spark.topProcessVramMB)) GB")
        }
        if spark.llmMonitoring { llm }
    }

    @ViewBuilder private var llm: some View {
        Divider().overlay(Palette.stroke)
        HStack {
            Text("LLM").font(mono(11, .bold)).tracking(1).foregroundStyle(Palette.dim)
            if !spark.postureLabel.isEmpty {
                let tint = spark.postureLevel == "ok" ? Palette.healthy : Palette.amber
                Text(spark.postureLabel).font(mono(10, .bold)).foregroundStyle(tint)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(tint.opacity(0.12)).overlay(Rectangle().stroke(tint.opacity(0.4)))
            }
            Spacer()
        }
        if let kv = spark.kvCacheUsage {
            Bar(label: "KV cache", value: FleetFormat.pct(kv), fraction: kv)
        }
        Grid(horizontalSpacing: 16, verticalSpacing: 4) {
            GridRow {
                Pair(label: "Prefill", value: "\(FleetFormat.tps(spark.prefillTps)) tok/s")
                Pair(label: "Slots", value: "\(spark.slotsActive) / \(spark.slotsTotal)")
            }
            GridRow {
                Pair(
                    label: "Requests",
                    value: "\(Int(spark.requestsRunning ?? 0)) run / \(Int(spark.requestsWaiting ?? 0)) wait",
                    warn: (spark.requestsWaiting ?? 0) > 0)
                Pair(label: "Context", value: spark.contextLength.map { FleetFormat.grouped($0) } ?? "—")
            }
            GridRow {
                Pair(label: "TTFT p95", value: FleetFormat.secs(spark.ttftP95))
                Pair(label: "Prefix hit", value: FleetFormat.pct(spark.prefixCacheHitRate))
            }
            GridRow {
                Pair(label: "ITL p95", value: FleetFormat.secs(spark.itlP95))
                Pair(label: "MTP accept", value: FleetFormat.pct(spark.mtpAcceptanceRate))
            }
        }
        Pair(label: "Generated", value: "\(FleetFormat.grouped(spark.totalOutputTokens)) tok")
    }
}

private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
