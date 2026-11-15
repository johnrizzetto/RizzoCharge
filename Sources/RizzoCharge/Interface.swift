import AppKit
import SwiftUI

private func routeTint(_ scheme: ColorScheme) -> Color {
    scheme == .dark ? Color(red: 0.26, green: 0.80, blue: 0.86) : Color(red: 0.0, green: 0.33, blue: 0.39)
}
private let panelShape = RoundedRectangle(cornerRadius: 16, style: .continuous)

struct SampleView<Content: View>: View {
    @ObservedObject var monitor: BatteryMonitor
    @ViewBuilder var content: (BatterySample?, String) -> Content

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let sample = monitor.reading?.fresh(at: .now, suspended: monitor.suspended)
            let status = sample?.state.label ?? (monitor.reading == nil ? "Reading power status" : "Readings out of date")
            content(sample, status)
        }
    }
}

private struct Surface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content
            .background {
                if reduceTransparency {
                    panelShape.fill(Color(nsColor: .controlBackgroundColor))
                } else {
                    panelShape.fill(Color.primary.opacity(0.045))
                }
            }
            .overlay(panelShape.strokeBorder(Color.primary.opacity(contrast == .increased ? 0.29 : 0.10), lineWidth: 1))
    }
}

private struct ProductMark: View {
    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            .frame(width: 32, height: 32)
            .accessibilityHidden(true)
    }
}

private struct ChargeHeader: View {
    var sample: BatterySample?
    var status: String
    var compact = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 12) {
            HStack(alignment: .center, spacing: 8) {
                ProductMark()
                Text("RizzoCharge").font(.headline).accessibilityAddTraits(.isHeader)
                Spacer()
                if !compact, let at = sample?.at {
                    Text("Read at \(at.formatted(date: .omitted, time: .standard))")
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(sample?.percent.map { "\($0)%" } ?? "Unavailable")
                    .font(.system(size: sample?.percent == nil ? 23 : compact ? 40 : 56, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .accessibilityLabel(sample?.percent.map { "Battery charge \($0) percent" } ?? "Battery charge unavailable")
                Label(status, systemImage: statusIcon)
                    .font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            if let percent = sample?.percent {
                ProgressView(value: Double(percent), total: 100)
                    .tint(routeTint(scheme))
                    .accessibilityHidden(true)
            }
        }
    }

    private var statusIcon: String {
        switch sample?.state {
        case .charging: return "bolt.fill"
        case .connected: return "powerplug"
        case .battery: return "battery.75percent"
        default: return "questionmark.circle"
        }
    }
}

struct MenuContent: View {
    @ObservedObject var monitor: BatteryMonitor
    var onDashboard: () -> Void
    var onDismiss: () -> Void
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        SampleView(monitor: monitor) { sample, status in
            VStack(alignment: .leading, spacing: 13) {
                ChargeHeader(sample: sample, status: status, compact: true)
                FlowPanel(sample: sample, compact: true)
                if let rating = sample?.adapterRating {
                    HStack {
                        Text("Adapter rating")
                        Spacer()
                        Text(watts(rating, decimals: 0)).monospacedDigit()
                    }.font(.caption).foregroundStyle(.secondary)
                }
                Button(action: onDashboard) {
                    Label("Open Dashboard", systemImage: "macwindow")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large).buttonStyle(.borderedProminent)
                .keyboardShortcut("d", modifiers: .command)

                HStack {
                    Button("Battery Settings") { monitor.openBatterySettings(); onDismiss() }
                    Spacer()
                    Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q", modifiers: .command)
                }.controlSize(.small)
            }
            .padding(16).frame(width: 352)
            .background {
                if reduceTransparency { Color(nsColor: .windowBackgroundColor) }
            }
        }
    }
}

struct Dashboard: View {
    @ObservedObject var monitor: BatteryMonitor
    @State private var showSources = false

    var body: some View {
        SampleView(monitor: monitor) { sample, status in
            ScrollView {
                VStack(alignment: .leading, spacing: 19) {
                    ChargeHeader(sample: sample, status: status)
                    FlowPanel(sample: sample)
                    HStack {
                        Text("Battery details").font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
                        Spacer()
                        Button { monitor.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                            .keyboardShortcut("r", modifiers: .command)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 175), spacing: 10)], alignment: .leading, spacing: 10) {
                        Metric("Cycle count", sample?.cycles.map(String.init), "Reported by macOS")
                        Metric("Adapter rating", sample?.adapterRating.map { watts($0, decimals: 0) }, "Rated wattage")
                        Metric("Battery power", sample?.packPower.map { watts(abs($0)) }, powerDetail(sample?.packPower))
                        Metric("Full-charge capacity", sample?.fullCapacity.map { "\($0.formatted()) mAh" }, "Registry estimate")
                        Metric("Design capacity", sample?.designCapacity.map { "\($0.formatted()) mAh" }, "Registry estimate")
                        Metric("Capacity ratio", sample?.capacityRatio.map { $0.formatted(.number.precision(.fractionLength(1))) + "%" }, "Full-charge ÷ design")
                    }
                    DisclosureGroup("Reading sources and limits", isExpanded: $showSources) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Charge, power state and adapter rating come from macOS. RizzoCharge polls every 5 seconds and refreshes on power changes and wake. The timestamp is when the app read the data. Battery firmware can update more slowly.")
                            Text("Battery power estimates pack flow from registry voltage and signed current. Cable input and Mac use are estimates from undocumented macOS fields on supported hardware. They appear when the readings agree with the input voltage, current and pack power. The estimates have not been checked against a power meter.")
                            Text("Capacity uses registry estimates. For Apple’s maximum capacity and condition, open Battery Health in System Settings.")
                            Text("The temperature sensor and its scale are unverified, so RizzoCharge does not show a temperature or issue heat alerts.")
                        }.font(.callout).foregroundStyle(.secondary).padding(.top, 9)
                    }
                    Divider()
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Charging controls stay with macOS").font(.headline)
                            Text("Automatic heat control is off. Use Battery Settings for Optimized Battery Charging and Charge Limit when available.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 12)
                        Button("Battery Settings") { monitor.openBatterySettings() }
                    }
                }
                .padding(24)
                .frame(maxWidth: 980)
                .frame(maxWidth: .infinity)
            }.frame(minWidth: 492, minHeight: 420)
        }

    }

    private func powerDetail(_ value: Double?) -> String {
        guard let value else { return "Pack estimate" }
        if value == 0 { return "No net flow reported" }
        return value > 0 ? "Into battery · estimate" : "From battery · estimate"
    }
}

private struct Metric: View {
    let title: String
    let value: String?
    let detail: String

    init(_ title: String, _ value: String?, _ detail: String) {
        self.title = title; self.value = value; self.detail = detail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
            Text(value ?? "Unavailable").font(.title3.weight(.semibold)).monospacedDigit()
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 65, alignment: .leading)
        .padding(12).modifier(Surface())
        .accessibilityElement(children: .combine)
    }
}

private func watts(_ n: Double, decimals: Int = 1) -> String {
    n.formatted(.number.precision(.fractionLength(decimals))) + " W"
}

private struct FlowPanel: View {
    var sample: BatterySample?
    var compact = false
    private var state: PowerState { sample?.state ?? .unknown }
    private var cableActive: Bool { state == .charging || state == .connected }
    private var batteryActive: Bool { state == .charging || state == .battery }
    private var cableText: String {
        if let estimate = sample?.acPowerEstimate { return estimatedWatts(estimate.inputWatts) }
        if cableActive { return "Estimate unavailable" }
        if state == .battery { return "Not supplying power" }
        return "Unknown"
    }
    private var macText: String {
        if let estimate = sample?.acPowerEstimate { return estimatedWatts(estimate.loadWatts) }
        return state == .unknown ? "Unknown" : "Estimate unavailable"
    }
    private func estimatedWatts(_ value: Double) -> String { watts(value) + " est." }

    private var batteryText: String {
        switch state {
        case .charging: return "Charging"
        case .connected: return "Not charging"
        case .battery: return "Supplying Mac"
        case .unknown: return "Unknown"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Power flow").font(compact ? .subheadline.weight(.semibold) : .headline)
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: 0) {
                endpoint("Cable input", cableText, "powerplug", active: cableActive)
                    .frame(width: compact ? 103 : 149, alignment: .leading)
                Routes(state: state).frame(height: 100).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 0) {
                    endpoint("Battery", batteryText, "battery.75percent", active: batteryActive).frame(height: 50)
                    endpoint("Mac use", macText, "laptopcomputer", active: state != .unknown).frame(height: 50)
                }
                .frame(width: compact ? 120 : 154, alignment: .leading)
                .padding(.leading, 8)
            }
            if !compact {
                Text(sample?.acPowerEstimate == nil
                     ? "Routes reflect the power state reported by macOS."
                     : "Wattages are estimates from macOS telemetry. Cable input excludes wall adapter losses.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(compact ? 12 : 16).modifier(Surface())
    }

    private func endpoint(_ title: String, _ subtitle: String, _ symbol: String, active: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
                .labelStyle(EndpointLabelStyle(active: active))
            Text(subtitle).font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }.accessibilityElement(children: .combine)
    }
}

private struct EndpointLabelStyle: LabelStyle {
    var active: Bool
    @Environment(\.colorScheme) private var scheme
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.foregroundStyle(active ? routeTint(scheme) : Color.secondary).accessibilityHidden(true)
            configuration.title
        }
    }
}

private struct Routes: View {
    let state: PowerState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24, paused: reduceMotion || state == .unknown)) { clock in
            Canvas { context, size in
                let x = size.width * 0.46
                let cable = CGPoint(x: 0, y: 50)
                let hub = CGPoint(x: x, y: 50)
                let upperHub = CGPoint(x: x, y: 25)
                let lowerHub = CGPoint(x: x, y: 75)
                let battery = CGPoint(x: size.width - 2, y: 25)
                let mac = CGPoint(x: size.width - 2, y: 75)
                func draw(_ points: [CGPoint], active: Bool, arrow: Bool = false) {
                    let color: Color = active ? routeTint(scheme) : .secondary.opacity(0.32)
                    var path = Path()
                    path.addLines(points)
                    context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    if active && arrow, let end = points.last {
                        var head = Path()
                        head.addLines([CGPoint(x: end.x - 4, y: end.y - 3), end, CGPoint(x: end.x - 4, y: end.y + 3)])
                        context.stroke(head, with: .color(color), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    }
                }
                let ac = state == .charging || state == .connected
                draw([cable, hub], active: ac)
                draw([hub, upperHub, battery], active: state == .charging || state == .battery, arrow: state == .charging)
                draw([hub, lowerHub, mac], active: state != .unknown, arrow: state != .unknown)

                // One uniform dot travels the reported route; speed and stroke are fixed.
                if !reduceMotion, state != .unknown {
                    let phase = clock.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.8) / 2.8
                    let toMac = ac ? [cable, hub, lowerHub, mac] : [battery, upperHub, lowerHub, mac]
                    func dot(_ points: [CGPoint], _ t: Double) {
                        let segments = zip(points, points.dropFirst()).map { p, q in (p, q, hypot(q.x - p.x, q.y - p.y)) }
                        var distance = segments.reduce(0) { $0 + $1.2 } * t
                        for (p, q, length) in segments where length > 0 {
                            if distance <= length {
                                let f = distance / length
                                let x = p.x + (q.x - p.x) * f
                                let y = p.y + (q.y - p.y) * f
                                context.fill(Path(ellipseIn: CGRect(x: x - 2, y: y - 2, width: 4, height: 4)), with: .color(routeTint(scheme)))
                                break
                            }
                            distance -= length
                        }
                    }
                    dot(toMac, phase)
                    if state == .charging { dot([cable, hub, upperHub, battery], phase) }
                }
            }
        }
    }
}
