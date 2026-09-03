import AppKit
import CoreAudio
import Foundation
import Synchronization

/// An app shown in the UI. A parent app may aggregate several audio processes
/// (e.g. Chrome and its helpers) that share one gain.
struct TrackedApp: Identifiable {
    let id: String          // gain key (parent bundle id, or "pid-"/"obj-" prefix)
    let name: String
    let icon: NSImage?
    let bundleID: String?
}

/// Container for the ring buffer indices; non-isolated so IOProc callbacks can
/// capture it by reference.
final class RingIndex: @unchecked Sendable {
    let write = Atomic<UInt64>(0)
    let read = Atomic<UInt64>(0)
}

/// Realtime diagnostics counters: written by the IOProcs, polled by the main
/// thread (refresh) and reported via NSLog. Reporting only — never read back
/// by the audio path, so they cannot affect behaviour.
final class DiagCounters: @unchecked Sendable {
    /// IOProc A: times the ring had no room and a whole callback was dropped.
    let ringDrops = Atomic<UInt64>(0)
    /// IOProc A: stereo samples dropped because the ring was full.
    let droppedSamples = Atomic<UInt64>(0)
    /// IOProc B: times a device callback could not be fully served from the ring.
    let underruns = Atomic<UInt64>(0)
    /// IOProc B: device frames emitted as silence because the ring was short.
    let starvedFrames = Atomic<UInt64>(0)
    /// IOProc B: device tick at the most recent underrun (0 = none yet).
    let lastUnderrunTick = Atomic<UInt64>(0)
    /// IOProc B: ring fill in stereo samples at callback start.
    let ringFill = Atomic<UInt64>(0)
    /// IOProc B: frames the output device asks for per callback.
    let devFramesPerCallback = Atomic<UInt64>(0)
}

/// Audio engine:
/// 1. Creates a private process tap (mutedWhenTapped) for every audio process —
///    the app's sound is muted at the source while being captured by the tap.
/// 2. All taps feed a private aggregate device; IOProc A continuously reads it
///    (reading keeps the mute in effect) and mixes per-app gains into a realtime
///    ring buffer.
/// 3. IOProc B is attached directly to the real output device and renders the
///    ring into the device output — the standard path every app uses to play.
///
/// Fail-open safety: any failure or watchdog trigger tears down all taps so apps
/// instantly return to native playback. When this app quits or crashes, taps are
/// destroyed with the connection, restoring native playback as well.
///
/// Version requirements: `AudioHardwareCreateProcessTap` needs macOS 14.2+, and
/// the `NSAudioCaptureUsageDescription` Info.plist key (Core Audio system-audio
/// capture) needs macOS 14.4+ — without that key taps capture only silence. The
/// current build targets macOS 15+ (Swift 6 Synchronization).
@MainActor
final class AudioEngine {

    private static let maxTaps = 64
    /// Back-off after a failed rebuild to avoid churn on the 2 s refresh cycle.
    private static let rebuildBackoff: TimeInterval = 5
    /// Watchdog: if an IOProc stops firing for this long, treat it as stalled.
    private static let watchdogSeconds: TimeInterval = 3
    /// Ring buffer: 2^15 samples (16384 stereo frames ≈ 340 ms at 48 kHz); a
    /// power of two so modulo wraps are cheap.
    private static let ringSize = 1 << 15
    /// Start playback with enough queued audio to absorb callback jitter. The
    /// output resampler then keeps the queue near this level as clocks drift.
    private static let targetRingFrames = 4096

    // MARK: - Realtime-thread shared state (IOProcs touch only raw pointers/atomics)

    private let gains = UnsafeMutablePointer<Float>.allocate(capacity: maxTaps)
    private let tapCount = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
    private let inputOffset = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
    private let devChannels = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
    private let devInterleaved = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
    private let scratch = UnsafeMutablePointer<Float>.allocate(capacity: 2048 * 2)
    private let ring = UnsafeMutablePointer<Float>.allocate(capacity: ringSize)
    private let ringIndex = RingIndex()
    private let diag = DiagCounters()
    /// IOProc B owns these after start; the main thread resets them while the
    /// device is stopped during rebuild.
    private let resamplePhase = UnsafeMutablePointer<Double>.allocate(capacity: 1)
    private let outputPrimed = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
    /// Incremented by IOProc A / B on every callback (watchdog input).
    private let tapIOTick = UnsafeMutablePointer<UInt64>.allocate(capacity: 1)
    private let devIOTick = UnsafeMutablePointer<UInt64>.allocate(capacity: 1)

    // MARK: - Main-thread state

    private(set) var apps: [TrackedApp] = []
    /// Real output device (master volume and IOProc B target).
    private(set) var outputDeviceID = AudioObjectID(kAudioObjectUnknown)
    private(set) var lastError: String?

    /// Per-app gain (linear 0–1), keyed by TrackedApp.id.
    var bundleGains: [String: Float] = [:]

    private var slotOwnerKey: [String] = []
    private var tappedObjs: [AudioObjectID] = []
    private var objKeys: [AudioObjectID: String] = [:]
    private var tapIDs: [AudioObjectID] = []
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var tapProcID: AudioDeviceIOProcID?
    private var deviceProcID: AudioDeviceIOProcID?
    private var ourProcessObj = AudioObjectID(kAudioObjectUnknown)
    private var lastRebuildAttempt = Date(timeIntervalSince1970: 0)
    private var lastTapTickSeen: UInt64 = 0
    private var lastDevTickSeen: UInt64 = 0
    private var lastTapTickTime = Date()
    private var lastDevTickTime = Date()
    // Diagnostic poll state (main thread only; logging has no effect on audio).
    private var lastPolledUnderruns: UInt64 = 0
    private var lastPolledRingDrops: UInt64 = 0
    private var lastPolledTapTick: UInt64 = 0
    private var lastPolledDevTick: UInt64 = 0
    private var starvedSince: Date?
    private var lastStarvedLog = Date()
    private var lastEventLog = Date(timeIntervalSince1970: 0)
    /// Last observed screen-recording permission; a change forces a rebuild so a
    /// fresh grant takes effect without relaunching.
    private var lastPermissionOK: Bool?
    private var initialDeviceMute: Bool?   // device mute at launch, restored on quit
    private var hasInitialMute = false
    /// Own bundle id (nil when running as a bare binary).
    private let ownBundleID = Bundle.main.bundleIdentifier?.lowercased()

    /// Number of active taps (for the UI "mixing" indicator).
    var activeTapCount: Int { Int(tapCount.pointee) }

    init() {
        gains.initialize(repeating: 1.0, count: Self.maxTaps)
        tapCount.pointee = 0
        inputOffset.pointee = 0
        devChannels.pointee = 2
        devInterleaved.pointee = 1
        scratch.initialize(repeating: 0, count: 2048 * 2)
        ring.initialize(repeating: 0, count: Self.ringSize)
        resamplePhase.pointee = 0
        outputPrimed.pointee = 0
    }

    // No deinit (MainActor-restricted): the pointer memory lives for the process
    // lifetime; stop() destroys all taps/IOProcs and restores native playback.

    // MARK: - Main loop

    /// Poll: enumerate audio processes, follow output-device changes, rebuild when needed.
    func refresh() {
        // Self-heal: if the default output is gone, restore a real device.
        let validOutputs = CADevice.outputDeviceIDs().filter { !Self.isOurDevice($0) }
        var out = CASystem.defaultOutputDevice()
        if out == AudioObjectID(kAudioObjectUnknown) || !validOutputs.contains(out) {
            // Prefer a non-display device (built-in speakers) over a display
            // (HDMI/DisplayPort) that may be powered off.
            let fallback = validOutputs.first(where: { !CADevice.isDisplay($0) })
                ?? validOutputs.first
            if let fallback {
                CASystem.setDefaultOutput(fallback)
                out = fallback
            } else {
                lastError = "No output device available"
                return
            }
        }
        var deviceChanged = false
        if out != outputDeviceID {
            outputDeviceID = out
            deviceChanged = true
        }
        lastError = nil

        if !hasInitialMute {
            initialDeviceMute = CADevice.isMuted(outputDeviceID)
            hasInitialMute = true
        }

        ourProcessObj = CASystem.processObject(forPID: getpid())

        // Map process objects back to PIDs (objects do not expose the PID directly).
        var pidByObj: [AudioObjectID: Int32] = [:]
        for app in NSWorkspace.shared.runningApplications {
            let obj = CASystem.processObject(forPID: app.processIdentifier)
            if obj != AudioObjectID(kAudioObjectUnknown) {
                pidByObj[obj] = app.processIdentifier
            }
        }

        // Group helper processes under their parent app (bundle id with helper
        // prefix, or same PID) so Chrome and its helpers share one gain.
        let regularApps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular
        }
        func parentApp(forBundle bundle: String?, pid: Int32?) -> NSRunningApplication? {
            if let b = bundle {
                for app in regularApps {
                    guard let ab = app.bundleIdentifier else { continue }
                    if b == ab || b.hasPrefix(ab + ".") { return app }
                }
            }
            if let pid, let app = regularApps.first(where: { $0.processIdentifier == pid }) {
                return app
            }
            return nil
        }

        // Gain key: parent bundle id, else bundle id, else pid, else object id.
        func gainKey(forBundle bundle: String?, pid: Int32?, obj: AudioObjectID,
                     parent: NSRunningApplication?) -> String {
            if let p = parent, let pb = p.bundleIdentifier, !pb.isEmpty { return pb.lowercased() }
            if let b = bundle, !b.isEmpty { return b.lowercased() }
            if let p = pid { return "pid-\(p)" }
            return "obj-\(obj)"
        }

        var grouped: [String: (name: String, icon: NSImage?, bundle: String?)] = [:]
        var targets: [AudioObjectID] = []
        for proc in CASystem.processObjectIDs() {
            guard proc != ourProcessObj else { continue }
            // Skip our own process (by bundle id in app mode).
            if let b = CAProcess.bundleID(proc)?.lowercased(), b == ownBundleID {
                continue
            }
            // Skip processes outputting to other devices (e.g. Bluetooth-only)
            // to avoid double playback.
            let devices = CADevice.outputDevices(ofProcess: proc)
            if !devices.isEmpty && !devices.contains(outputDeviceID) { continue }

            let bundle = CAProcess.bundleID(proc)
            let pid = pidByObj[proc]
            let parent = parentApp(forBundle: bundle, pid: pid)
            let key = gainKey(forBundle: bundle, pid: pid, obj: proc, parent: parent)

            let entry = grouped[key] ?? {
                if let parent {
                    return (parent.localizedName ?? bundle ?? "App", parent.icon,
                            parent.bundleIdentifier ?? bundle)
                }
                let name: String
                if let b = bundle, !b.isEmpty {
                    name = b
                } else if let pid {
                    name = NSRunningApplication(processIdentifier: pid)?.localizedName
                        ?? "PID \(pid)"
                } else {
                    name = "Audio Process #\(proc)"
                }
                return (name, nil, bundle)
            }()
            grouped[key] = entry
            objKeys[proc] = key
            targets.append(proc)
        }

        apps = grouped.map { key, e in
            TrackedApp(id: key, name: e.name, icon: e.icon, bundleID: e.bundle)
        }
        apps.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        // Rebuild when targets, output device, or permission changed; back off
        // after a failure.
        let permOK = CGPreflightScreenCaptureAccess()
        let permissionChanged = lastPermissionOK.map { $0 != permOK } ?? false
        lastPermissionOK = permOK

        let needRebuild = deviceChanged || permissionChanged || Set(targets) != Set(tappedObjs)
        if needRebuild, Date().timeIntervalSince(lastRebuildAttempt) > Self.rebuildBackoff {
            rebuild(targets: targets)
            lastRebuildAttempt = Date()
        }
        checkWatchdog()
        logDiagnostics()
    }

    /// Watchdog: if either IOProc stops firing, tear down and restore native playback.
    private func checkWatchdog() {
        guard aggregateID != AudioObjectID(kAudioObjectUnknown),
              tapCount.pointee > 0 else { return }
        let now = Date()
        let tapTick = tapIOTick.pointee
        let devTick = devIOTick.pointee
        if tapTick != lastTapTickSeen {
            lastTapTickSeen = tapTick
            lastTapTickTime = now
        }
        if devTick != lastDevTickSeen {
            lastDevTickSeen = devTick
            lastDevTickTime = now
        }
        if now.timeIntervalSince(lastTapTickTime) > Self.watchdogSeconds
            || now.timeIntervalSince(lastDevTickTime) > Self.watchdogSeconds {
            lastError = "Audio callbacks stalled; restored native playback"
            teardown()
        }
    }

    /// Poll the IOProc diagnostics counters and NSLog trouble signs: ring
    /// starvation (device callbacks that cannot be fully served while both
    /// IOProcs keep firing — the watchdog cannot see this) and dropped tap
    /// callbacks. Diagnostic only; never changes audio state.
    private func logDiagnostics() {
        guard aggregateID != AudioObjectID(kAudioObjectUnknown), tapCount.pointee > 0 else {
            // Engine down or native pass-through: nothing to report. Reset the
            // poll state so the next episode starts from a clean slate.
            starvedSince = nil
            lastPolledUnderruns = diag.underruns.load(ordering: .relaxed)
            lastPolledRingDrops = diag.ringDrops.load(ordering: .relaxed)
            lastPolledTapTick = tapIOTick.pointee
            lastPolledDevTick = devIOTick.pointee
            return
        }

        let now = Date()
        let underruns = diag.underruns.load(ordering: .relaxed)
        let ringDrops = diag.ringDrops.load(ordering: .relaxed)
        let starvedFrames = diag.starvedFrames.load(ordering: .relaxed)
        let fill = diag.ringFill.load(ordering: .relaxed)
        let devFrames = diag.devFramesPerCallback.load(ordering: .relaxed)
        let tapTick = tapIOTick.pointee
        let devTick = devIOTick.pointee
        let tapAdvancing = tapTick != lastPolledTapTick
        let devAdvancing = devTick != lastPolledDevTick
        let newUnderruns = underruns &- lastPolledUnderruns
        let newRingDrops = ringDrops &- lastPolledRingDrops
        lastPolledUnderruns = underruns
        lastPolledRingDrops = ringDrops
        lastPolledTapTick = tapTick
        lastPolledDevTick = devTick

        // Every underrun records the device tick it happened on; a recent one
        // means starvation is ongoing right now, not a one-off glitch.
        let lastUnderrunTick = diag.lastUnderrunTick.load(ordering: .relaxed)
        let starvingNow = lastUnderrunTick != 0 && (devTick &- lastUnderrunTick) < 10

        if starvingNow {
            if starvedSince == nil {
                starvedSince = now
                NSLog("[PerAppVolume] diag: starvation started: ring fill \(fill)/\(Self.ringSize), device needs \(devFrames)/callback; IOProcs firing tap=\(tapAdvancing ? "y" : "n") dev=\(devAdvancing ? "y" : "n"); silence so far \(starvedFrames) frames")
            } else if now.timeIntervalSince(lastStarvedLog) > 10, let since = starvedSince {
                lastStarvedLog = now
                NSLog("[PerAppVolume] diag: still starving for \(Int(now.timeIntervalSince(since)))s; +\(newUnderruns) underruns since last poll, ring fill \(fill), cumulative silence \(starvedFrames) frames")
            }
        } else {
            if let since = starvedSince {
                starvedSince = nil
                NSLog("[PerAppVolume] diag: starvation ended after \(Int(now.timeIntervalSince(since)))s; cumulative underruns \(underruns), silence inserted \(starvedFrames) frames")
            }
            if newUnderruns > 0 || newRingDrops > 0 {
                if now.timeIntervalSince(lastEventLog) > 30 {
                    lastEventLog = now
                    NSLog("[PerAppVolume] diag: transient +\(newUnderruns) underruns, +\(newRingDrops) tap drops since last poll; ring fill \(fill) vs device \(devFrames)/callback")
                }
            }
        }
    }

    func stop() {
        // Restore the device mute state captured at launch (the master mute
        // button changes the hardware, so it must be restored on quit).
        if hasInitialMute, let m = initialDeviceMute,
           outputDeviceID != AudioObjectID(kAudioObjectUnknown),
           CADevice.isMuted(outputDeviceID) != m {
            CADevice.setMuted(outputDeviceID, m)
        }
        teardown()
        apps = []
    }

    // MARK: - Gains

    func gain(forKey key: String) -> Float {
        bundleGains[key] ?? 1.0
    }

    func setGain(_ gain: Float, forKey key: String) {
        let g = min(max(gain, 0), 1)
        bundleGains[key] = g
        for (i, owner) in slotOwnerKey.enumerated() where owner == key && i < Self.maxTaps {
            gains[i] = g
        }
    }

    /// Gain keys of the current tap slots (used to replay gains onto a new build).
    func slotOwnerKeys() -> [String] { slotOwnerKey }

    func applyGain(_ g: Float, slot: Int) {
        guard slot < Self.maxTaps else { return }
        gains[slot] = min(max(g, 0), 1)
    }

    // MARK: - Master volume (hardware volume of the real output device)

    func masterVolume() -> Float {
        CADevice.volumeScalar(outputDeviceID)
    }

    func setMasterVolume(_ v: Float) {
        CADevice.setVolumeScalar(outputDeviceID, v)
    }

    func isMasterMuted() -> Bool {
        CADevice.isMuted(outputDeviceID)
    }

    func setMasterMuted(_ m: Bool) {
        CADevice.setMuted(outputDeviceID, m)
    }

    // MARK: - Build / teardown

    private func rebuild(targets: [AudioObjectID]) {
        // Fail open without screen-recording permission: never intercept audio.
        if !CGPreflightScreenCaptureAccess() {
            lastError = "Screen Recording permission required: System Settings → Privacy & Security → Screen Recording"
            teardownTaps()
            tappedObjs = []
            return
        }
        teardown()
        tappedObjs = []
        lastError = nil
        guard outputDeviceID != AudioObjectID(kAudioObjectUnknown) else { return }

        // 1) Private taps (reading mutes the source).
        var newTapIDs: [AudioObjectID] = []
        var tapUIDs: [String] = []
        var owners: [String] = []
        var objs: [AudioObjectID] = []
        for obj in targets {
            let slot = newTapIDs.count
            if slot >= Self.maxTaps { break }
            let desc = CATapDescription()
            desc.name = "PerAppVolume-\(obj)"
            desc.isPrivate = true
            desc.muteBehavior = .mutedWhenTapped
            desc.isMono = false
            desc.isMixdown = true
            desc.isExclusive = false
            // `processes` is NS_REFINED in Swift; pass the object id via KVC.
            desc.setValue([NSNumber(value: obj)], forKey: "processes")

            var tapID = AudioObjectID(kAudioObjectUnknown)
            let status = AudioHardwareCreateProcessTap(desc, &tapID)
            guard status == noErr, tapID != AudioObjectID(kAudioObjectUnknown),
                  let uid = CATap2.uid(tapID) else {
                NSLog("[PerAppVolume] failed to create tap obj=\(obj) status=\(status)")
                continue
            }
            newTapIDs.append(tapID)
            tapUIDs.append(uid)
            owners.append(targetsKey(for: obj))
            objs.append(obj)
            gains[slot] = bundleGains[owners.last!] ?? 1.0
        }
        tapIDs = newTapIDs
        slotOwnerKey = owners
        tapCount.pointee = Int32(newTapIDs.count)

        guard !newTapIDs.isEmpty else {
            NSLog("[PerAppVolume] no interceptable processes; native playback")
            tappedObjs = []
            return
        }

        // 2) Private aggregate device collecting only the tap inputs. The
        // aggregate must never reference the real output device, or it would
        // take over that device's output path and silence other clients.
        let aggUID = "local.perappvolume.aggregate.\(Int(Date().timeIntervalSince1970 * 1000))"
        let desc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "PerAppVolume",
            kAudioAggregateDeviceUIDKey: aggUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: tapUIDs.map {
                [kAudioSubTapUIDKey: $0, kAudioSubTapDriftCompensationKey: true]
            },
        ]
        var aggID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(desc as CFDictionary, &aggID)
        guard status == noErr, aggID != AudioObjectID(kAudioObjectUnknown) else {
            lastError = "Failed to create aggregate device: \(status)"
            NSLog("[PerAppVolume] CreateAggregateDevice failed: \(status)")
            teardownTaps()
            return
        }
        aggregateID = aggID

        // A tap-only aggregate otherwise chooses its own nominal rate. On some
        // boots that differs from the physical output (commonly 44.1 vs 48 kHz),
        // making the output drain the ring until playback becomes all silence.
        // Match the rates first; the adaptive output resampler below handles
        // the remaining clock drift between the independent devices.
        let outputRate = CADevice.nominalSampleRate(outputDeviceID)
        if outputRate > 0 {
            let setRate = CADevice.setNominalSampleRate(aggID, outputRate)
            let actualRate = CADevice.nominalSampleRate(aggID)
            if !setRate || abs(actualRate - outputRate) > 0.5 {
                NSLog("[PerAppVolume] aggregate rate \(actualRate) could not be aligned to output rate \(outputRate); adaptive resampling enabled")
            }
        }

        // 3) Tap buffer layout.
        let inAddr = CA.address(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput)
        let inputBufferCount = bufferCount(aggID, inAddr)
        inputOffset.pointee = Int32(max(0, inputBufferCount - newTapIDs.count))

        // 4) Output device format (for IOProc B).
        if let fmt = outputFormat(outputDeviceID) {
            devChannels.pointee = Int32(max(1, Int(fmt.mChannelsPerFrame)))
            let nonInterleaved = fmt.mFormatFlags & UInt32(kAudioFormatFlagIsNonInterleaved) != 0
            devInterleaved.pointee = nonInterleaved ? 0 : 1
        }
        ringIndex.write.store(0, ordering: .relaxed)
        ringIndex.read.store(0, ordering: .relaxed)
        resamplePhase.pointee = 0
        outputPrimed.pointee = 0

        // 5) IOProc A (aggregate input → mix → ring).
        let tapBlock = makeTapMixBlock()
        var tapProc: AudioDeviceIOProcID?
        let tapCreate = AudioDeviceCreateIOProcIDWithBlock(&tapProc, aggID, nil, tapBlock)
        guard tapCreate == noErr, let tapProc else {
            lastError = "Failed to create aggregate IOProc: \(tapCreate)"
            NSLog("[PerAppVolume] aggregate IOProc create failed: \(tapCreate)")
            teardownAggregate()
            return
        }
        tapProcID = tapProc
        let tapStart = AudioDeviceStart(aggID, tapProc)
        guard tapStart == noErr else {
            lastError = "Failed to start aggregate IOProc: \(tapStart)"
            NSLog("[PerAppVolume] aggregate IOProc start failed: \(tapStart)")
            teardownAggregate()
            return
        }

        // 6) IOProc B (real output device: ring → speakers).
        let devBlock = makeDeviceOutputBlock()
        var devProc: AudioDeviceIOProcID?
        let devCreate = AudioDeviceCreateIOProcIDWithBlock(&devProc, outputDeviceID, nil, devBlock)
        guard devCreate == noErr, let devProc else {
            lastError = "Failed to create device IOProc: \(devCreate)"
            NSLog("[PerAppVolume] device IOProc create failed: \(devCreate)")
            teardownAggregate()
            return
        }
        deviceProcID = devProc
        let devStart = AudioDeviceStart(outputDeviceID, devProc)
        guard devStart == noErr else {
            lastError = "Failed to start device IOProc: \(devStart)"
            NSLog("[PerAppVolume] device IOProc start failed: \(devStart)")
            teardownAggregate()
            return
        }

        tappedObjs = objs
        lastTapTickSeen = tapIOTick.pointee
        lastDevTickSeen = devIOTick.pointee
        lastTapTickTime = Date()
        lastDevTickTime = Date()
        // Fresh episode for the diagnostics poll state (counters keep running).
        lastPolledUnderruns = diag.underruns.load(ordering: .relaxed)
        lastPolledRingDrops = diag.ringDrops.load(ordering: .relaxed)
        lastPolledTapTick = tapIOTick.pointee
        lastPolledDevTick = devIOTick.pointee
        starvedSince = nil
    }

    private func targetsKey(for obj: AudioObjectID) -> String {
        objKeys[obj] ?? "obj-\(obj)"
    }

    /// Whether the device is one of our aggregates (excluded from self-heal).
    private static func isOurDevice(_ id: AudioObjectID) -> Bool {
        let name = CADevice.name(id)
        let uid = CADevice.uid(id) ?? ""
        return name == "PerAppVolume" || uid.hasPrefix("local.perappvolume.")
    }

    private func teardownAggregate() {
        if let proc = tapProcID, aggregateID != AudioObjectID(kAudioObjectUnknown) {
            AudioDeviceStop(aggregateID, proc)
            AudioDeviceDestroyIOProcID(aggregateID, proc)
        }
        tapProcID = nil
        if aggregateID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        teardownTaps()
        tapCount.pointee = 0
    }

    private func teardown() {
        teardownAggregate()
        if let proc = deviceProcID, outputDeviceID != AudioObjectID(kAudioObjectUnknown) {
            AudioDeviceStop(outputDeviceID, proc)
            AudioDeviceDestroyIOProcID(outputDeviceID, proc)
        }
        deviceProcID = nil
    }

    private func teardownTaps() {
        for tap in tapIDs { AudioHardwareDestroyProcessTap(tap) }
        tapIDs = []
        slotOwnerKey = []
    }

    private func outputFormat(_ device: AudioObjectID) -> AudioStreamBasicDescription? {
        let addr = CA.address(kAudioDevicePropertyStreamFormat, kAudioObjectPropertyScopeOutput)
        let (status, data) = CA.raw(device, addr)
        guard status == noErr, let data, data.count >= MemoryLayout<AudioStreamBasicDescription>.size else {
            return nil
        }
        return data.withUnsafeBytes { $0.load(as: AudioStreamBasicDescription.self) }
    }

    private func bufferCount(_ obj: AudioObjectID, _ addr: AudioObjectPropertyAddress) -> Int {
        var a = addr
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(obj, &a, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(obj, &a, 0, nil, &size, raw) == noErr else { return 0 }
        let abl = raw.assumingMemoryBound(to: AudioBufferList.self)
        return Int(abl.pointee.mNumberBuffers)
    }

    // MARK: - Realtime callbacks

    /// IOProc A: read aggregate input (taps), mix by gain into scratch, write ring.
    private func makeTapMixBlock() -> AudioDeviceIOBlock {
        let gains = self.gains
        let tapCountP = self.tapCount
        let offsetP = self.inputOffset
        let tapIOTickP = self.tapIOTick
        let scratch = self.scratch
        let ring = self.ring
        let ringIndex = self.ringIndex
        let ringSize = Self.ringSize
        let diag = self.diag

        return { _, inInputData, _, _, _ in
            tapIOTickP.pointee &+= 1
            let inBL = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
            let count = Int(tapCountP.pointee)
            let offset = Int(offsetP.pointee)
            guard count > 0, !inBL.isEmpty else { return }

            memset(scratch, 0, 2048 * 2 * MemoryLayout<Float>.size)

            var maxFrames = 0
            for t in 0..<count {
                let idx = offset + t
                guard idx < inBL.count else { break }
                let inBuf = inBL[idx]
                guard let inRaw = inBuf.mData else { continue }
                let inFloats = inRaw.assumingMemoryBound(to: Float.self)

                // AudioBuffer already reports its channel count. Deriving it
                // from byte size after assuming 8 bytes/frame made the old
                // mono test always resolve to stereo and could read past mono
                // buffers.
                let chIn = max(1, Int(inBuf.mNumberChannels))
                let frames = Int(inBuf.mDataByteSize) / MemoryLayout<Float>.size / chIn
                guard frames > 0 else { continue }
                let n = min(frames, 2048)
                maxFrames = max(maxFrames, n)
                let g = gains[t]
                if g == 0 { continue }

                if chIn >= 2 {
                    for f in 0..<n {
                        scratch[f * 2] += inFloats[f * chIn] * g
                        scratch[f * 2 + 1] += inFloats[f * chIn + 1] * g
                    }
                } else {
                    for f in 0..<n {
                        scratch[f * 2] += inFloats[f] * g
                        scratch[f * 2 + 1] += inFloats[f] * g
                    }
                }
            }
            guard maxFrames > 0 else { return }

            // Write the ring (stereo sample count; drop this callback if full).
            let w = ringIndex.write.load(ordering: .relaxed)
            let r = ringIndex.read.load(ordering: .acquiring)
            let used = Int(w &- r)
            let space = ringSize - used
            let samples = maxFrames * 2
            guard space >= samples else {
                diag.ringDrops.add(1, ordering: .relaxed)
                diag.droppedSamples.add(UInt64(samples), ordering: .relaxed)
                return
            }
            let base = Int(w) & (ringSize - 1)
            let first = min(samples, ringSize - base)
            for i in 0..<first { ring[base + i] = scratch[i] }
            for i in first..<samples { ring[i - first] = scratch[i] }
            ringIndex.write.store(w &+ UInt64(samples), ordering: .releasing)
        }
    }

    /// IOProc B: render ring data into the real output device.
    private func makeDeviceOutputBlock() -> AudioDeviceIOBlock {
        let ring = self.ring
        let ringIndex = self.ringIndex
        let ringSize = Self.ringSize
        let devChannelsP = self.devChannels
        let devInterleavedP = self.devInterleaved
        let devIOTickP = self.devIOTick
        let resamplePhaseP = self.resamplePhase
        let outputPrimedP = self.outputPrimed
        let targetFrames = Self.targetRingFrames
        let diag = self.diag

        return { _, _, _, outOutputData, _ in
            devIOTickP.pointee &+= 1
            let outBL = UnsafeMutableAudioBufferListPointer(outOutputData)
            guard outBL.count > 0 else { return }

            let chOut = Int(devChannelsP.pointee)
            let interleaved = devInterleavedP.pointee != 0
            let framesOut: Int
            if interleaved {
                framesOut = Int(outBL[0].mDataByteSize) / 4 / max(chOut, 1)
            } else {
                framesOut = Int(outBL[0].mDataByteSize) / 4
            }
            guard framesOut > 0 else { return }
            diag.devFramesPerCallback.store(UInt64(framesOut), ordering: .relaxed)

            let r = ringIndex.read.load(ordering: .relaxed)
            let w = ringIndex.write.load(ordering: .acquiring)
            let avail = Int(w &- r) / 2   // available frames (stereo)
            diag.ringFill.store(UInt64(avail * 2), ordering: .relaxed)

            // Always clear the complete hardware buffer first. This is also
            // correct for mono and interleaved devices with more than 2 channels.
            if interleaved {
                if let raw = outBL[0].mData {
                    memset(raw, 0, Int(outBL[0].mDataByteSize))
                }
            } else {
                for c in 0..<outBL.count {
                    if let raw = outBL[c].mData {
                        memset(raw, 0, Int(outBL[c].mDataByteSize))
                    }
                }
            }

            // Do not begin at an empty ring: prefill once so normal scheduling
            // jitter cannot immediately cause a repeating underrun.
            if outputPrimedP.pointee == 0 {
                guard avail >= targetFrames else { return }
                outputPrimedP.pointee = 1
                resamplePhaseP.pointee = 0
            }

            // Proportional queue controller. At the target it consumes exactly
            // one captured frame per output frame. If the ring drains/fills, a
            // bounded linear resampler consumes slightly slower/faster. The wide
            // bound also survives a 44.1/48 kHz mismatch if HAL rejected the
            // aggregate-rate request.
            let fillError = Double(avail - targetFrames) / Double(targetFrames)
            let ratio = min(1.15, max(0.85, 1.0 + fillError * 0.25))
            let startPhase = resamplePhaseP.pointee
            var produced = 0
            if avail >= 2 {
                let maxPosition = Double(avail - 1)
                while produced < framesOut,
                      startPhase + Double(produced) * ratio < maxPosition {
                    produced += 1
                }
            }
            if produced < framesOut {
                diag.underruns.add(1, ordering: .relaxed)
                diag.starvedFrames.add(UInt64(framesOut - produced), ordering: .relaxed)
                diag.lastUnderrunTick.store(devIOTickP.pointee, ordering: .relaxed)
            }
            let base = Int(r) & (ringSize - 1)

            @inline(__always) func ringSample(_ frame: Int, _ channel: Int) -> Float {
                ring[(base + frame * 2 + channel) & (ringSize - 1)]
            }

            @inline(__always) func interpolated(_ outputFrame: Int, _ channel: Int) -> Float {
                let position = startPhase + Double(outputFrame) * ratio
                let frame = Int(position)
                let fraction = Float(position - Double(frame))
                let a = ringSample(frame, channel)
                return a + (ringSample(frame + 1, channel) - a) * fraction
            }

            if interleaved {
                guard let dstRaw = outBL[0].mData else { return }
                let dst = dstRaw.assumingMemoryBound(to: Float.self)
                if chOut == 1 {
                    for f in 0..<produced {
                        dst[f] = (interpolated(f, 0) + interpolated(f, 1)) * 0.5
                    }
                } else {
                    for f in 0..<produced {
                        dst[f * chOut] = interpolated(f, 0)
                        dst[f * chOut + 1] = interpolated(f, 1)
                    }
                }
            } else {
                // Non-interleaved: one buffer per channel.
                for c in 0..<min(chOut, outBL.count) {
                    guard let dstRaw = outBL[c].mData else { continue }
                    let dst = dstRaw.assumingMemoryBound(to: Float.self)
                    if c < 2 {
                        for f in 0..<produced {
                            dst[f] = interpolated(f, c)
                        }
                    }
                }
            }

            // Keep the fractional source position for the next callback and
            // advance only by complete captured frames.
            if produced > 0 {
                let endPhase = startPhase + Double(produced) * ratio
                let consumed = min(Int(endPhase), max(0, avail - 1))
                resamplePhaseP.pointee = endPhase - Double(consumed)
                ringIndex.read.store(r &+ UInt64(consumed * 2), ordering: .releasing)
            }
        }
    }
}
