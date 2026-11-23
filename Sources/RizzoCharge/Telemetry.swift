import AppKit
import Combine
import IOKit.ps

enum PowerState: String, Codable, Equatable {
    case charging, connected, battery, unknown

    init(ac: Bool?, charging: Bool?) {
        switch (ac, charging) {
        case (true?, true?): self = .charging
        case (true?, false?): self = .connected
        case (false?, false?): self = .battery
        default: self = .unknown
        }
    }

    var label: String {
        switch self {
        case .charging: return "Charging"
        case .connected: return "Connected, not charging"
        case .battery: return "On battery"
        case .unknown: return "Power state unknown"
        }
    }
}

struct BatterySample: Encodable {
    var at: Date
    var state: PowerState
    var percent: Int?
    var minutesToFull: Int?
    var minutesToEmpty: Int?
    var cycles: Int?
    var adapterRating: Double?
    var voltage: Double?
    var current: Double?
    var packPower: Double?
    var reportedPackPower: Double?
    var fullCapacity: Int?
    var designCapacity: Int?
    var temperatureCandidate: Double?
    var systemPowerInRaw: Double?
    var systemLoadRaw: Double?
    var acPowerEstimate: ACPowerEstimate?

    var minutesTo80Percent: Int? {
        guard state == .charging, let percent, (0...100).contains(percent) else { return nil }
        if percent >= 80 { return 0 }
        guard let minutesToFull else { return nil }
        // Use the share of the remaining charge. Charging can slow near full.
        return Int(ceil(Double(minutesToFull) * Double(80 - percent) / Double(100 - percent)))
    }

    var capacityRatio: Double? {
        guard let fullCapacity, let designCapacity, designCapacity > 0 else { return nil }
        return 100 * Double(fullCapacity) / Double(designCapacity)
    }

    func fresh(at now: Date, suspended: Bool = false) -> Self? {
        !suspended && (0...15).contains(now.timeIntervalSince(at)) ? self : nil
    }
}

func chargePercent(current: Double?, maximum: Double?) -> Int? {
    guard let current, let maximum, current.isFinite, maximum.isFinite,
          maximum > 0, current >= 0, current <= maximum else { return nil }
    return Int((100 * (current / maximum)).rounded())
}

private func number(_ value: Any?) -> NSNumber? {
    guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
          n.doubleValue.isFinite else { return nil }
    return n
}

func timeEstimateMinutes(_ value: Any?) -> Int? {
    guard let minutes = number(value)?.doubleValue,
          (0..<65_535).contains(minutes), minutes.rounded() == minutes else { return nil }
    return Int(minutes)
}

func signedMilliamps(_ value: NSNumber?) -> Double? {
    guard let n = number(value) else { return nil }
    // Negative registry values may arrive as unsigned two's-complement.
    let integer = Double(n.int64Value)
    guard abs(integer) <= 30_000 else { return nil }
    let encoding = String(cString: n.objCType)
    guard !["f", "d"].contains(encoding) || n.doubleValue == integer else { return nil }
    return integer
}

func batteryWatts(millivolts: Double?, milliamps: Double?) -> Double? {
    guard let millivolts, let milliamps, (1...30_000).contains(millivolts),
          (-30_000...30_000).contains(milliamps) else { return nil }
    return millivolts * milliamps / 1_000_000
}

func consistentBatteryWatts(_ watts: Double?, state: PowerState) -> Double? {
    guard let watts, watts.isFinite else { return nil }
    switch state {
    case .charging: return watts >= 0 ? watts : nil
    case .battery, .connected: return watts <= 0 ? watts : nil
    case .unknown: return nil
    }
}

func reportedChargingWatts(milliwatts: Double?, calculated: Double?, state: PowerState) -> Double? {
    // The registry field's units were checked against charging telemetry on this Mac.
    guard state == .charging, let milliwatts, (1...150_000).contains(milliwatts) else { return nil }
    let watts = milliwatts / 1000
    if let calculated, abs(watts - calculated) > max(1, watts * 0.08) { return nil }
    return watts
}

/// Undocumented, same-origin Mac estimates. Consistency checks reject suspect
/// frames; they cannot establish accuracy or a hardware sample timestamp.
struct ACPowerEstimate: Encodable {
    let inputWatts: Double
    let loadWatts: Double

    init?(state: PowerState, inputMilliwatts: Double?, loadMilliwatts: Double?,
          inputMillivolts: Double?, inputMilliamps: Double?, packWatts: Double?) {
        guard state == .charging || state == .connected,
              let inputMilliwatts, (100...150_000).contains(inputMilliwatts),
              let loadMilliwatts, (100...150_000).contains(loadMilliwatts),
              let inputMillivolts, (3_000...50_000).contains(inputMillivolts),
              let inputMilliamps, (1...10_000).contains(inputMilliamps),
              let packWatts, packWatts.isFinite else { return nil }
        let input = inputMilliwatts / 1000
        let load = loadMilliwatts / 1000
        let inputFromVI = inputMillivolts * inputMilliamps / 1_000_000
        // Allow small timing differences between registry channels.
        let tolerance = max(1.0, input * 0.08)
        guard abs(input - inputFromVI) <= tolerance,
              abs(input - load - packWatts) <= tolerance else { return nil }
        inputWatts = input
        loadWatts = load
    }
}

enum BatteryReader {
    private static let supportsRegistryPower: Bool = {
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 27 else { return false }
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return false }
        var model = [CChar](repeating: 0, count: size)
        let status = model.withUnsafeMutableBufferPointer { buffer in
            sysctlbyname("hw.model", buffer.baseAddress, &size, nil, 0)
        }
        return status == 0 && String(cString: model) == "Mac16,12"
    }()

    static func sample() -> BatterySample {
        var result = BatterySample(at: Date(), state: .unknown, percent: nil)
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() {
            for source in sources as [AnyObject] {
                guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                      d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
                result.percent = chargePercent(current: number(d[kIOPSCurrentCapacityKey])?.doubleValue,
                                               maximum: number(d[kIOPSMaxCapacityKey])?.doubleValue)
                let ac: Bool?
                switch d[kIOPSPowerSourceStateKey] as? String {
                case kIOPSACPowerValue?: ac = true
                case kIOPSBatteryPowerValue?: ac = false
                default: ac = nil
                }
                let flag = d[kIOPSIsChargingKey] as? NSNumber
                let charging = flag.flatMap { CFGetTypeID($0) == CFBooleanGetTypeID() ? $0.boolValue : nil }
                result.state = PowerState(ac: ac, charging: charging)
                switch result.state {
                case .charging:
                    result.minutesToFull = timeEstimateMinutes(d[kIOPSTimeToFullChargeKey])
                case .battery:
                    result.minutesToEmpty = timeEstimateMinutes(d[kIOPSTimeToEmptyKey])
                case .connected, .unknown:
                    break
                }
                if ac == true,
                   let details = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any],
                   let rating = number(details[kIOPSPowerAdapterWattsKey])?.doubleValue,
                   (1...1000).contains(rating) { result.adapterRating = rating }
                break
            }
        }
        withService("AppleSmartBattery") { service in
            func value(_ key: String) -> Double? { number(property(service, key))?.doubleValue }
            func integer(_ n: Double?, range: ClosedRange<Double>) -> Int? {
                guard let n, range.contains(n), n.rounded() == n else { return nil }
                return Int(n)
            }
            let data = property(service, "BatteryData") as? [String: Any]
            result.cycles = integer(value("CycleCount"), range: 0...100_000)
            result.fullCapacity = integer(number(data?["FullChargeCapacity"])?.doubleValue, range: 1...100_000)
            result.designCapacity = integer(number(data?["DesignCapacity"])?.doubleValue, range: 1...100_000)
            let mv = value("Voltage").flatMap { (1...30_000).contains($0) ? $0 : nil }
            let ma = signedMilliamps(property(service, "InstantAmperage") as? NSNumber)
            result.voltage = mv.map { $0 / 1000 }
            result.current = ma.map { $0 / 1000 }
            let calculated = batteryWatts(millivolts: mv, milliamps: ma)
            if supportsRegistryPower {
                result.reportedPackPower = reportedChargingWatts(
                    milliwatts: number(data?["BatteryPower"])?.doubleValue,
                    calculated: calculated,
                    state: result.state
                )
            }
            result.packPower = result.reportedPackPower ?? consistentBatteryWatts(calculated, state: result.state)
            let candidates = property(service, "PowerTelemetryData") as? [String: Any]
            result.systemPowerInRaw = number(candidates?["SystemPowerIn"])?.doubleValue
            result.systemLoadRaw = number(candidates?["SystemLoad"])?.doubleValue
            if supportsRegistryPower {
                result.acPowerEstimate = ACPowerEstimate(
                    state: result.state, inputMilliwatts: result.systemPowerInRaw,
                    loadMilliwatts: result.systemLoadRaw,
                    inputMillivolts: number(candidates?["SystemVoltageIn"])?.doubleValue,
                    inputMilliamps: number(candidates?["SystemCurrentIn"])?.doubleValue,
                    packWatts: result.packPower
                )
            }
        }
        withService("AppleSmartBatteryPack") { service in
            let data = property(service, "BatteryData") as? [String: Any]
            // Keep raw. A plausible conversion is not validation of this sensor or scale.
            result.temperatureCandidate = number(data?["Temperature"])?.doubleValue
        }
        return result
    }

    private static func withService(_ name: String, _ block: (io_service_t) -> Void) {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(name))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }
        block(service)
    }

    private static func property(_ service: io_service_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}

private final class PowerCallback {
    weak var monitor: BatteryMonitor?
    init(_ monitor: BatteryMonitor) { self.monitor = monitor }
}

@MainActor final class BatteryMonitor: ObservableObject {
    @Published private(set) var reading: BatterySample?
    @Published private(set) var suspended = false
    private var timer: Timer?
    private var observations: [NSObjectProtocol] = []
    private var source: CFRunLoopSource?
    private var callback: PowerCallback?

    init() {
        refresh()
        timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }

        callback = PowerCallback(self)
        if let callback,
           let registration = IOPSNotificationCreateRunLoopSource({ context in
               guard let context else { return }
               let target = Unmanaged<PowerCallback>.fromOpaque(context).takeUnretainedValue()
               MainActor.assumeIsolated { target.monitor?.refresh() }
           }, Unmanaged.passUnretained(callback).toOpaque())?.takeRetainedValue() {
            source = registration
            CFRunLoopAddSource(CFRunLoopGetMain(), registration, .commonModes)
        }
        let center = NSWorkspace.shared.notificationCenter
        observations.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) {
            [weak self] _ in MainActor.assumeIsolated { self?.suspended = true }
        })
        observations.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated {
                self?.reading = nil
                self?.suspended = false
                self?.refresh()
            }
        })
    }

    deinit {
        timer?.invalidate()
        if let source { CFRunLoopSourceInvalidate(source) }
        for observation in observations { NSWorkspace.shared.notificationCenter.removeObserver(observation) }
    }

    func refresh() {
        guard !suspended else { return }
        reading = BatteryReader.sample()
    }

    func openBatterySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.battery") {
            NSWorkspace.shared.open(url)
        }
    }
}
