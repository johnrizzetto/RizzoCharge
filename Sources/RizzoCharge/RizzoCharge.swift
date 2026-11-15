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

private func statusItemImage(_ sample: BatterySample?) -> NSImage {
    let value = sample?.percent.map { "\($0)%" } ?? ""
    let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
    let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
    let text = value as NSString
    let width = value.isEmpty ? 20 : 23 + ceil(text.size(withAttributes: attributes).width)
    let symbol = sample?.state == .charging ? "battery.100percent.bolt" : "battery.75percent"
    let icon = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
    let image = NSImage(size: NSSize(width: width, height: 22), flipped: false) { _ in
        if let icon {
            icon.draw(in: NSRect(x: 0, y: (22 - icon.size.height) / 2, width: icon.size.width, height: icon.size.height))
        }
        text.draw(at: NSPoint(x: 23, y: 4), withAttributes: attributes)
        return true
    }
    image.isTemplate = true
    return image
}
