# App Volume (PerAppVolume)

A macOS menu bar app that **controls volume per app**. No driver, no admin
privileges.

## Usage

1. Open `PerAppVolume.app` (build it first, see below) or copy it from `dist/`.
2. **Grant Screen Recording on first launch**: macOS uses the Screen Recording
   permission to protect the ability to capture other apps' audio. The system
   prompts on first launch; you can also enable it manually under
   System Settings → Privacy & Security → Screen Recording.
   Without the permission the app intercepts nothing (native playback
   continues) and the panel shows a red banner.
3. Click the 🔊 menu bar icon to open the panel:
   - **Master**: volume and mute of the current output device.
   - **One row per app**: slider for volume (0–100%), speaker button for
     mute/unmute.
   - **Remember Volumes** (on by default): per-app volumes are persisted by
     bundle id and restored on next launch.
   - **Launch at Login**: start App Volume automatically when you log in
     (installs a LaunchAgent at `~/Library/LaunchAgents/`).
4. **Quit** via the button at the bottom. All apps instantly resume native
   playback — no volume changes are left behind.

> This app never modifies system-level volume settings; per-app volume exists
> only in its own mix path while it runs.

## How it works (macOS 26)

macOS 26 removed the old per-process volume mechanism
(`kAudioHardwarePropertyProcessList` returns `kAudioHardwareUnknownPropertyError`),
so the app uses the new official API:

1. **Enumerate**: `kAudioHardwarePropertyProcessObjectList` ('prs#') lists all
   process objects connected to the audio system; PIDs are resolved via
   `kAudioHardwarePropertyTranslatePIDToProcessObject` ('id2p').
2. **Intercept**: a **private process tap** (`AudioHardwareCreateProcessTap`,
   macOS 14.2+) is created for each process object with
   `CATapMutedWhenTapped` — the app's sound is muted at the source while being
   captured by the tap.
3. **Mix**: all taps feed a private aggregate device; IOProc A continuously
   reads it (reading keeps the mute in effect) and mixes per-app gains into a
   realtime ring buffer; **IOProc B is attached directly to the real output
   device** and renders the ring into the device output — the standard path
   every app uses to play.

Fail-open safety: on any failure, watchdog trigger, or when this app quits or
crashes, all taps are destroyed and every app immediately resumes native
playback. If the default output device goes stale, the app restores a real
device.

## Build

```bash
./scripts/build.sh                 # builds dist/PerAppVolume.app (release)
cp -R dist/PerAppVolume.app ~/Applications/
```

`build.sh` signs with the self-signed "PerAppVolume Dev" identity when present
(so the Screen Recording grant survives rebuilds and no real developer identity
is exposed), falling back to an ad-hoc signature otherwise.

Building on your own machine requires **no certificate configuration**:
`build.sh` falls back to an ad-hoc signature automatically and the app works
as-is. The only caveat is that with an ad-hoc signature, macOS treats each
rebuild as a new app, so you must re-grant Screen Recording after every
rebuild (a one-time grant per build; no impact if you build once and use it).
To avoid re-granting on rebuilds, create your own stable self-signed identity
once: generate a code-signing certificate named "PerAppVolume Dev", import it
into your login keychain with `security import`, and mark it trusted with
`security add-trusted-cert -d -r trustRoot -k ~/Library/Keychains/login.keychain-db`.

Notes:

- The Core Audio system-audio capture (macOS 14.4+) requires
  `NSAudioCaptureUsageDescription` in Info.plist; without it taps capture only
  silence.
- The app bundles a pre-built icon (`scripts/AppIcon.icns`); icon generation
  tooling is intentionally not part of the repository.

## Requirements

- The current build targets macOS 15+ (Swift 6 Synchronization). The underlying
  APIs: process taps (`AudioHardwareCreateProcessTap`) require macOS 14.2+, and
  the `NSAudioCaptureUsageDescription` Info.plist key requires macOS 14.4+.
- Verified on macOS 26.

## Known limitations

- Only processes outputting to the **current default output device** are
  controlled; processes routed elsewhere (e.g. Bluetooth-only apps) keep native
  playback.
- Playback through the app adds a small amount of latency (tens of ms).
- DRM-protected content (some streaming media) may not be capturable; such apps
  keep native playback.

## Diagnostics

While intercepting, the engine reports IOProc health to the unified log under
`[PerAppVolume] diag:` (Console app, or `log stream --predicate 'eventMessage
CONTAINS "PerAppVolume"'`). These lines are reporting only — nothing in the
engine reacts to them:

- `starvation started / still starving / starvation ended`: device callbacks
  that could not be fully served from the ring while both IOProcs kept firing —
  the signature of ring underrun that the watchdog (which only detects stopped
  callbacks) cannot see. Includes ring fill vs. the device buffer size and
  cumulative silence frames.
- `transient +N underruns, +M tap drops`: occasional shortfalls that
  self-healed, plus tap-side drops when the ring was full.

## License

[MIT](LICENSE)


```
Sources/PerAppVolume/
  main.swift            entry point (app launch, single-instance guard)
  CoreAudioSupport.swift CoreAudio property helpers (prs# / id2p / tap / device)
  AudioEngine.swift     audio engine: tap interception + aggregate + realtime mix
  AppModel.swift        UI state, volume persistence
  ContentView.swift     menu bar popover UI (SwiftUI)
  AppDelegate.swift     status bar icon / popover / quit cleanup
scripts/build.sh        packaging script
scripts/Info.plist      LSUIElement (no Dock icon)
scripts/AppIcon.icns    pre-built app icon
```
