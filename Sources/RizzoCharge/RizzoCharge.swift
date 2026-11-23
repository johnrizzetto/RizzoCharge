import AppKit
import Combine
import SwiftUI

@main enum RizzoChargeLauncher {
    @MainActor static func main() {
        if CommandLine.arguments.dropFirst().first == "--snapshot" {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            do {
                print(String(decoding: try encoder.encode(BatteryReader.sample()), as: UTF8.self))
            } catch {
                fputs("RizzoCharge could not encode the battery snapshot.\n", stderr)
                exit(EXIT_FAILURE)
            }
            return
        }
        let app = NSApplication.shared
        let delegate = RizzoChargeDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor private final class RizzoChargeDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let monitor = BatteryMonitor()
    private let popover = NSPopover()
    private var statusItem: NSStatusItem?
    private var update: AnyCancellable?
    private var dashboard: NSWindow?
    private let previewAppearance: NSAppearance? = {
        switch ProcessInfo.processInfo.environment["RIZZOCHARGE_PREVIEW_APPEARANCE"] {
        case "light": return NSAppearance(named: .aqua)
        case "dark": return NSAppearance(named: .darkAqua)
        default: return nil
        }
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let previewAppearance { NSApp.appearance = previewAppearance }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "RizzoCharge.Power"
        statusItem = item
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        popover.behavior = .transient
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: MenuContent(
            monitor: monitor,
            onDashboard: { [weak self] in self?.showDashboard() },
            onDismiss: { [weak self] in self?.popover.close() }
        ))
        if let previewAppearance { popover.appearance = previewAppearance }
        update = monitor.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.updateItem() }
        }
        updateItem()
        if CommandLine.arguments.contains("--show-popover") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.togglePopover() }
        } else {
            showDashboard()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showDashboard()
        return false
    }

    func popoverDidShow(_ notification: Notification) {
        popover.contentViewController?.view.window?.makeKey()
    }

    @objc private func togglePopover() {
        if popover.isShown { popover.performClose(nil); return }
        guard let button = statusItem?.button else { return }
        monitor.refresh()
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    private func updateItem() {
        let sample = monitor.reading?.fresh(at: .now, suspended: monitor.suspended)
        let button = statusItem?.button
        button?.image = statusItemImage(sample)
        button?.setAccessibilityLabel("RizzoCharge, \(sample?.percent.map { "\($0) percent" } ?? "charge unavailable"), \(sample?.state.label ?? "readings unavailable")")
        button?.toolTip = "RizzoCharge"
    }

    private func showDashboard() {
        popover.close()
        if dashboard == nil {
            let controller = NSHostingController(rootView: Dashboard(monitor: monitor))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 758),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.contentViewController = controller
            window.setContentSize(NSSize(width: 720, height: 758))
            window.contentMinSize = NSSize(width: 492, height: 420)
            window.title = "RizzoCharge"
            if let previewAppearance { window.appearance = previewAppearance }
            window.isReleasedWhenClosed = false
            window.center()
            dashboard = window
        }
        NSApp.activate(ignoringOtherApps: true)
        dashboard?.makeKeyAndOrderFront(nil)
    }
}

func batteryFillRect(in interior: CGRect, percent: Int?) -> CGRect {
    var fill = interior
    fill.size.width *= CGFloat(min(100, max(0, percent ?? 0))) / 100
    return fill
}

private func statusItemImage(_ sample: BatterySample?) -> NSImage {
    let charging = sample?.state == .charging
    let percent = sample?.percent
    let text = (percent.map { "\($0)%" } ?? "?") as NSString
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
        .foregroundColor: NSColor.white
    ]
    let fillColor: NSColor
    switch (charging, percent ?? 0) {
    case (_, 0...10): fillColor = NSColor(srgbRed: 0.69, green: 0.16, blue: 0.21, alpha: 1)
    case (_, 11...20): fillColor = NSColor(srgbRed: 0.56, green: 0.34, blue: 0.06, alpha: 1)
    case (true, _): fillColor = NSColor(srgbRed: 0.04, green: 0.49, blue: 0.29, alpha: 1)
    default: fillColor = NSColor(srgbRed: 0.08, green: 0.39, blue: 0.62, alpha: 1)
    }

    let body = CGRect(x: 1, y: 3, width: 48, height: 16)
    let interior = body.insetBy(dx: 1.5, dy: 1.5)
    return NSImage(size: NSSize(width: 53, height: 22), flipped: false) { _ in
        let border = NSColor(srgbRed: 0.60, green: 0.64, blue: 0.67, alpha: 1)
        border.setFill()
        NSBezierPath(roundedRect: body, xRadius: 4, yRadius: 4).fill()
        NSBezierPath(roundedRect: CGRect(x: 49.5, y: 8, width: 2.5, height: 6),
                     xRadius: 1.25, yRadius: 1.25).fill()
        let track = NSBezierPath(roundedRect: interior, xRadius: 2.5, yRadius: 2.5)
        NSColor(srgbRed: 0.15, green: 0.18, blue: 0.21, alpha: 1).setFill()
        track.fill()
        NSGraphicsContext.saveGraphicsState()
        track.addClip()
        fillColor.setFill()
        NSBezierPath.fill(batteryFillRect(in: interior, percent: percent))
        NSGraphicsContext.restoreGraphicsState()

        let textSize = text.size(withAttributes: attributes)
        let startX = body.midX - (textSize.width + (charging ? 10 : 0)) / 2
        if charging {
            let bolt = NSBezierPath()
            bolt.move(to: CGPoint(x: startX + 5, y: 16))
            bolt.line(to: CGPoint(x: startX, y: 10))
            bolt.line(to: CGPoint(x: startX + 3, y: 10))
            bolt.line(to: CGPoint(x: startX + 2, y: 6))
            bolt.line(to: CGPoint(x: startX + 7, y: 12))
            bolt.line(to: CGPoint(x: startX + 4, y: 12))
            bolt.close()
            NSColor.white.setFill()
            bolt.fill()
        }
        text.draw(at: CGPoint(x: startX + (charging ? 10 : 0), y: body.midY - textSize.height / 2),
                  withAttributes: attributes)
        return true
    }
}
