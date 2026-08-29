import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // Audio taps capture other apps' audio, gated by the Screen Recording
        // permission. Without it the engine intercepts nothing (fail-open).
        // Preflight alone does not register the app in the Settings list, so
        // request permission explicitly when it is missing.
        if !CGPreflightScreenCaptureAccess() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                CGRequestScreenCaptureAccess()
                self?.showPermissionAlert()
            }
        }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "speaker.wave.2.fill",
                                   accessibilityDescription: "App volume control")
            button.toolTip = "App Volume"
            button.target = self
            button.action = #selector(togglePopover)
        }
        statusItem = item

        let pop = NSPopover()
        pop.behavior = .transient
        pop.contentSize = NSSize(width: 360, height: 460)
        pop.contentViewController = NSHostingController(rootView: ContentView(model: model))
        popover = pop

        model.start()
    }

    @objc private func togglePopover() {
        guard let pop = popover, let button = statusItem?.button else { return }
        if pop.isShown {
            pop.performClose(nil)
        } else {
            pop.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            pop.contentViewController?.view.window?.makeKey()
        }
    }

    /// First-launch permission guidance alert.
    private func showPermissionAlert() {
        guard !CGPreflightScreenCaptureAccess() else { return }
        let alert = NSAlert()
        alert.messageText = "Screen Recording Permission Required"
        alert.informativeText = "App Volume captures system audio to control each app's volume, "
            + "which macOS protects with the Screen Recording permission.\n\n"
            + "Enable \"App Volume\" under System Settings → Privacy & Security → Screen Recording "
            + "(if it does not appear in the list, drag PerAppVolume.app into it), "
            + "then quit and relaunch the app.\n\n"
            + "A recording indicator will appear in the menu bar — this is macOS's mandatory "
            + "privacy indicator for audio-capturing apps. Audio is processed locally only."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            model.openScreenRecordingSettings()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Destroy taps and the aggregate so all apps resume native playback.
        model.stop()
    }
}
