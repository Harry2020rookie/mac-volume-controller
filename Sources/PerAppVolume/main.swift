import AppKit
import Foundation

// Single-instance guard: two instances creating taps on the same processes
// conflict and silence the output. flock is released automatically by the
// kernel on process exit (including crash or kill).
let lockPath = "/tmp/dev.zcode.perappvolume.lock"
let lockFD = open(lockPath, O_CREAT | O_RDWR, 0o644)
if lockFD < 0 {
    FileHandle.standardError.write("Unable to create instance lock \(lockPath)\n".data(using: .utf8)!)
    exit(1)
}
if flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
    // Another instance is already running: bring it to the front and exit.
    if let existing = NSRunningApplication
        .runningApplications(withBundleIdentifier: "dev.zcode.perappvolume")
        .first(where: { $0.processIdentifier != getpid() }) {
        existing.activate()
    }
    print("PerAppVolume is already running; exiting this instance")
    exit(0)
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()
