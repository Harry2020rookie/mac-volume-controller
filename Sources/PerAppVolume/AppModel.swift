import AppKit
import CoreAudio
import Foundation

@MainActor
final class AppModel: ObservableObject {

    @Published var apps: [TrackedApp] = []
    @Published var needsPermission = false
    @Published var rememberVolumes: Bool
    @Published var engineActive = false
    @Published var masterVolume: Double = 0
    @Published var masterMuted = false
    @Published var launchAtLogin = false
    @Published var lastError: String?

    let engine = AudioEngine()

    private var timer: Timer?
    private var lastNonzeroGain: [String: Float] = [:]   // for restore after mute
    private let defaults = UserDefaults.standard
    private let keyPrefix = "gain."

    init() {
        launchAtLogin = Self.isLaunchAtLoginEnabled()
        let raw = defaults.object(forKey: "rememberVolumes")
        rememberVolumes = (raw as? Bool) ?? true
        // Restore remembered volumes.
        let saved = defaults.dictionaryRepresentation()
        for (k, v) in saved {
            guard k.hasPrefix(keyPrefix), let d = v as? Double else { continue }
            let key = String(k.dropFirst(keyPrefix.count))
            engine.bundleGains[key] = Float(d)
        }
    }

    func start() {
        let t = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        refresh()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        engine.stop()
    }

    // MARK: - Refresh

    func refresh() {
        engine.refresh()
        needsPermission = !CGPreflightScreenCaptureAccess()
        apps = engine.apps
        engineActive = engine.activeTapCount > 0
        lastError = engine.lastError
        masterVolume = Double(engine.masterVolume())
        masterMuted = engine.isMasterMuted()
    }

    // MARK: - Volume

    func volume(for app: TrackedApp) -> Double {
        Double(engine.gain(forKey: app.id))
    }

    func setVolume(_ value: Double, for app: TrackedApp) {
        let g = Float(min(max(value, 0), 1))
        if g > 0 { lastNonzeroGain[app.id] = g }
        engine.setGain(g, forKey: app.id)
        if rememberVolumes {
            defaults.set(Double(g), forKey: keyPrefix + app.id)
        } else {
            defaults.removeObject(forKey: keyPrefix + app.id)
        }
    }

    func isMuted(_ app: TrackedApp) -> Bool {
        volume(for: app) <= 0.001
    }

    func toggleMute(_ app: TrackedApp) {
        if isMuted(app) {
            let restore = lastNonzeroGain[app.id] ?? 1.0
            setVolume(Double(restore), for: app)
        } else {
            lastNonzeroGain[app.id] = Float(volume(for: app))
            setVolume(0, for: app)
        }
    }

    // MARK: - Master volume

    func setMasterVolume(_ v: Double) {
        masterVolume = v
        engine.setMasterVolume(Float(v))
    }

    func toggleMasterMute() {
        masterMuted.toggle()
        engine.setMasterMuted(masterMuted)
    }

    // MARK: - Launch at login

    private static let launchAgentLabel = "dev.zcode.perappvolume"

    private static var launchAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(launchAgentLabel).plist")
    }

    /// Enabled when the launch agent is installed and points at this binary
    /// (so a moved app is not silently left with a stale agent).
    private static func isLaunchAtLoginEnabled() -> Bool {
        guard let data = try? Data(contentsOf: launchAgentURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [],
                                                                      format: nil) as? [String: Any],
              let args = plist["ProgramArguments"] as? [String],
              args.first == Bundle.main.executablePath
        else { return false }
        return true
    }

    func setLaunchAtLogin(_ on: Bool) {
        if on {
            let plist: [String: Any] = [
                "Label": Self.launchAgentLabel,
                "ProgramArguments": [Bundle.main.executablePath ?? ""],
                "RunAtLoad": true,
            ]
            do {
                try FileManager.default.createDirectory(at: Self.launchAgentURL.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                let data = try PropertyListSerialization.data(fromPropertyList: plist,
                                                              format: .xml, options: 0)
                try data.write(to: Self.launchAgentURL)
                runLaunchctl(["bootout", "gui/\(getuid())/\(Self.launchAgentLabel)"])
                runLaunchctl(["bootstrap", "gui/\(getuid())", Self.launchAgentURL.path])
            } catch {
                lastError = "Failed to enable launch at login: \(error.localizedDescription)"
            }
        } else {
            runLaunchctl(["bootout", "gui/\(getuid())/\(Self.launchAgentLabel)"])
            try? FileManager.default.removeItem(at: Self.launchAgentURL)
        }
        launchAtLogin = Self.isLaunchAtLoginEnabled()
    }

    private func runLaunchctl(_ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        try? process.run()
        process.waitUntilExit()
    }

    // MARK: - Permission

    /// Open the Screen Recording section of System Settings.
    func openScreenRecordingSettings() {
        let modern = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture")
        let legacy = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        if let modern, NSWorkspace.shared.open(modern) { return }
        if let legacy { NSWorkspace.shared.open(legacy) }
    }

    // MARK: - Persistence toggle

    func setRememberVolumes(_ on: Bool) {
        rememberVolumes = on
        defaults.set(on, forKey: "rememberVolumes")
        if on {
            // Reload persisted volumes and replay them onto the current slots.
            engine.bundleGains.removeAll()
            let saved = defaults.dictionaryRepresentation()
            for (k, v) in saved {
                guard k.hasPrefix(keyPrefix), let d = v as? Double else { continue }
                engine.bundleGains[String(k.dropFirst(keyPrefix.count))] = Float(d)
            }
            for (i, owner) in engine.slotOwnerKeys().enumerated() {
                engine.applyGain(engine.bundleGains[owner] ?? 1.0, slot: i)
            }
        }
    }
}
