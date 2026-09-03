import CoreAudio
import Foundation

/// Small helpers for reading/writing CoreAudio HAL properties
/// (macOS 26 process-object architecture).
enum CA {
    static let systemObject = AudioObjectID(kAudioObjectSystemObject)
    static let mainElement = kAudioObjectPropertyElementMain

    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        _ element: AudioObjectPropertyElement = mainElement) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func has(_ obj: AudioObjectID, _ addr: AudioObjectPropertyAddress) -> Bool {
        var a = addr
        return AudioObjectHasProperty(obj, &a)
    }

    /// Read a fixed-size scalar property; returns fallback on failure.
    static func scalar<T>(_ obj: AudioObjectID, _ addr: AudioObjectPropertyAddress, _ fallback: T) -> T {
        var a = addr
        var value = fallback
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(obj, &a, 0, nil, &size, $0)
        }
        return status == noErr ? value : fallback
    }

    @discardableResult
    static func setScalar<T>(_ obj: AudioObjectID, _ addr: AudioObjectPropertyAddress, _ value: T) -> Bool {
        var a = addr
        var v = value
        return withUnsafePointer(to: &v) {
            AudioObjectSetPropertyData(obj, &a, 0, nil, UInt32(MemoryLayout<T>.size), $0) == noErr
        }
    }

    /// Read a variable-length array property.
    static func array<T>(_ obj: AudioObjectID, _ addr: AudioObjectPropertyAddress, _ type: T.Type) -> [T] {
        var a = addr
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(obj, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<T>.stride
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                   alignment: MemoryLayout<T>.alignment)
        defer { raw.deallocate() }
        var sz = size
        guard AudioObjectGetPropertyData(obj, &a, 0, nil, &sz, raw) == noErr else { return [] }
        let typed = raw.bindMemory(to: T.self, capacity: count)
        return Array(UnsafeBufferPointer(start: typed, count: count))
    }

    static func cfString(_ obj: AudioObjectID, _ addr: AudioObjectPropertyAddress) -> String? {
        var a = addr
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString?
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(obj, &a, 0, nil, &size, $0)
        }
        guard status == noErr, let s = value else { return nil }
        return s as String
    }

    /// Read a fixed-size scalar qualified by a value (e.g. PID → process object).
    static func scalarQualified<T>(_ obj: AudioObjectID, _ addr: AudioObjectPropertyAddress,
                                   qualifier: UnsafeRawPointer, qualifierSize: UInt32,
                                   _ fallback: T) -> T {
        var a = addr
        var value = fallback
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(obj, &a, qualifierSize, qualifier, &size, $0)
        }
        return status == noErr ? value : fallback
    }

    /// Read a variable-size property into raw data (e.g. AudioBufferList).
    static func raw(_ obj: AudioObjectID, _ addr: AudioObjectPropertyAddress) -> (OSStatus, Data?) {
        var a = addr
        var size = UInt32(0)
        let st = AudioObjectGetPropertyDataSize(obj, &a, 0, nil, &size)
        guard st == noErr, size > 0 else { return (st, nil) }
        var buf = Data(count: Int(size))
        let st2 = buf.withUnsafeMutableBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return kAudioHardwareUnspecifiedError }
            var sz = size
            return AudioObjectGetPropertyData(obj, &a, 0, nil, &sz, base)
        }
        return (st2, st2 == noErr ? buf : nil)
    }
}

/// System-level queries.
enum CASystem {
    static func defaultOutputDevice() -> AudioObjectID {
        CA.scalar(CA.systemObject, CA.address(kAudioHardwarePropertyDefaultOutputDevice),
                  AudioObjectID(kAudioObjectUnknown))
    }

    @discardableResult
    static func setDefaultOutput(_ id: AudioObjectID) -> Bool {
        CA.setScalar(CA.systemObject, CA.address(kAudioHardwarePropertyDefaultOutputDevice), id)
    }

    static func allDeviceIDs() -> [AudioObjectID] {
        CA.array(CA.systemObject, CA.address(kAudioHardwarePropertyDevices), AudioObjectID.self)
    }

    /// All audio process objects on the system (macOS 26 mechanism, replaces prcl).
    static func processObjectIDs() -> [AudioObjectID] {
        CA.array(CA.systemObject, CA.address(kAudioHardwarePropertyProcessObjectList), AudioObjectID.self)
    }

    /// PID → process object.
    static func processObject(forPID pid: Int32) -> AudioObjectID {
        // NSRunningApplication can report a negative PID for apps that are
        // terminating; UInt32 would trap on it.
        guard pid > 0 else { return AudioObjectID(kAudioObjectUnknown) }
        var p = UInt32(pid)
        return withUnsafePointer(to: &p) {
            CA.scalarQualified(CA.systemObject,
                               CA.address(kAudioHardwarePropertyTranslatePIDToProcessObject),
                               qualifier: $0, qualifierSize: UInt32(MemoryLayout<UInt32>.size),
                               AudioObjectID(kAudioObjectUnknown))
        }
    }
}

/// Device-level queries.
enum CADevice {
    static func uid(_ id: AudioObjectID) -> String? {
        CA.cfString(id, CA.address(kAudioDevicePropertyDeviceUID))
    }

    static func name(_ id: AudioObjectID) -> String {
        CA.cfString(id, CA.address(kAudioObjectPropertyName))
            ?? CA.cfString(id, CA.address(kAudioDevicePropertyDeviceNameCFString))
            ?? "Device \(id)"
    }

    static func isOutputDevice(_ id: AudioObjectID) -> Bool {
        !CA.array(id, CA.address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput),
                  AudioObjectID.self).isEmpty
    }

    /// HDMI/DisplayPort outputs are usually displays that may be off; they should
    /// not be used as a fallback output.
    static func isDisplay(_ id: AudioObjectID) -> Bool {
        let t = CA.scalar(id, CA.address(kAudioDevicePropertyTransportType), UInt32(0))
        return t == kAudioDeviceTransportTypeHDMI || t == kAudioDeviceTransportTypeDisplayPort
    }

    static func outputDeviceIDs() -> [AudioObjectID] {
        allDeviceIDs().filter { isOutputDevice($0) }
    }

    static func nominalSampleRate(_ id: AudioObjectID) -> Double {
        CA.scalar(id, CA.address(kAudioDevicePropertyNominalSampleRate), Double(0))
    }

    @discardableResult
    static func setNominalSampleRate(_ id: AudioObjectID, _ rate: Double) -> Bool {
        guard rate > 0 else { return false }
        return CA.setScalar(id, CA.address(kAudioDevicePropertyNominalSampleRate), rate)
    }

    static func allDeviceIDs() -> [AudioObjectID] {
        CASystem.allDeviceIDs()
    }

    /// Output devices a process object currently uses.
    static func outputDevices(ofProcess proc: AudioObjectID) -> [AudioObjectID] {
        CA.array(proc, CA.address(kAudioProcessPropertyDevices, kAudioObjectPropertyScopeOutput),
                 AudioObjectID.self)
    }

    /// Master output volume (0–1) and mute.
    static func volumeScalar(_ id: AudioObjectID) -> Float {
        let scope = kAudioObjectPropertyScopeOutput
        let addr = CA.address(kAudioDevicePropertyVolumeScalar, scope, CA.mainElement)
        if CA.has(id, addr) {
            return CA.scalar(id, addr, Float(0))
        }
        // Some devices expose volume only on channels 1/2.
        let ch1 = CA.address(kAudioDevicePropertyVolumeScalar, scope, 1)
        return CA.has(id, ch1) ? CA.scalar(id, ch1, Float(0)) : 0
    }

    static func setVolumeScalar(_ id: AudioObjectID, _ v: Float) {
        let scope = kAudioObjectPropertyScopeOutput
        let val = min(max(v, 0), 1)
        let addr = CA.address(kAudioDevicePropertyVolumeScalar, scope, CA.mainElement)
        if CA.has(id, addr) {
            CA.setScalar(id, addr, val)
            return
        }
        for ch in [AudioObjectPropertyElement(1), AudioObjectPropertyElement(2)] {
            let a = CA.address(kAudioDevicePropertyVolumeScalar, scope, ch)
            if CA.has(id, a) { CA.setScalar(id, a, val) }
        }
    }

    static func isMuted(_ id: AudioObjectID) -> Bool {
        let scope = kAudioObjectPropertyScopeOutput
        let addr = CA.address(kAudioDevicePropertyMute, scope, CA.mainElement)
        return CA.has(id, addr) ? CA.scalar(id, addr, UInt32(0)) != 0 : false
    }

    static func setMuted(_ id: AudioObjectID, _ m: Bool) {
        let scope = kAudioObjectPropertyScopeOutput
        let addr = CA.address(kAudioDevicePropertyMute, scope, CA.mainElement)
        if CA.has(id, addr) { CA.setScalar(id, addr, UInt32(m ? 1 : 0)) }
    }
}

/// Process-object queries (macOS 26 mechanism).
enum CAProcess {
    static func bundleID(_ proc: AudioObjectID) -> String? {
        CA.cfString(proc, CA.address(kAudioProcessPropertyBundleID))
    }

    /// Whether the process has an active output IO.
    static func isRunningOutput(_ proc: AudioObjectID) -> Bool {
        CA.scalar(proc, CA.address(kAudioProcessPropertyIsRunningOutput), UInt32(0)) != 0
    }

    static func isRunning(_ proc: AudioObjectID) -> Bool {
        CA.scalar(proc, CA.address(kAudioProcessPropertyIsRunning), UInt32(0)) != 0
    }
}

/// Tap helpers.
enum CATap2 {
    static func uid(_ tapID: AudioObjectID) -> String? {
        CA.cfString(tapID, CA.address(kAudioTapPropertyUID))
    }
}
