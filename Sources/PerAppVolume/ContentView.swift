import AppKit
import SwiftUI

/// Menu bar popover: master volume plus per-app volume sliders / mute.
struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            masterRow
            Divider()
            if model.apps.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "speaker.slash")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text("No apps currently playing")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                List(model.apps) { app in
                    AppRowView(model: model, app: app)
                }
            }
            Divider()
            footer
        }
        .frame(width: 380, height: 480)
    }

    private var header: some View {
        VStack(spacing: 0) {
            if model.needsPermission {
                permissionBanner
            }
            HStack {
                Text("App Volume")
                    .font(.headline)
                Spacer()
                if model.engineActive {
                    Text("Mixing")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("\(model.apps.count) apps")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    /// Permission banner: explanation plus one-click System Settings.
    private var permissionBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("Screen Recording permission required for per-app volume (native playback continues meanwhile)")
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Grant") { model.openScreenRecordingSettings() }
                .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Color.red.opacity(0.08))
    }

    private var masterRow: some View {
        HStack(spacing: 10) {
            Button(action: { model.toggleMasterMute() }) {
                Image(systemName: model.masterMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .foregroundStyle(model.masterMuted ? Color.red : Color.secondary)
            }
            .buttonStyle(.plain)
            .help("Mute master output")
            Text("Master")
                .font(.system(size: 13))
                .frame(width: 52, alignment: .leading)
            Slider(value: Binding(
                get: { model.masterVolume },
                set: { model.setMasterVolume($0) }
            ), in: 0...1)
            .controlSize(.small)
            Text("\(Int((model.masterVolume * 100).rounded()))%")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var footer: some View {
        VStack(spacing: 6) {
            HStack(spacing: 16) {
                Toggle("Remember Volumes", isOn: Binding(
                    get: { model.rememberVolumes },
                    set: { model.setRememberVolumes($0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(.caption)
                .help("On: restore per-app volumes on next launch. Off: apps resume native playback when quitting.")
                Toggle("Launch at Login", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(.caption)
                .help("Start App Volume automatically when you log in.")
                Spacer()
            }
            HStack {
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

private struct AppRowView: View {
    @ObservedObject var model: AppModel
    let app: TrackedApp

    private var volumeBinding: Binding<Double> {
        Binding(
            get: { model.volume(for: app) },
            set: { model.setVolume($0, for: app) }
        )
    }

    var body: some View {
        HStack(spacing: 10) {
            icon
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(app.name)
                    .font(.system(size: 13))
                    .lineLimit(1)
                if let bid = app.bundleID {
                    Text(bid)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                model.toggleMute(app)
            } label: {
                Image(systemName: model.isMuted(app) ? "speaker.slash.fill" : "speaker.fill")
                    .foregroundStyle(model.isMuted(app) ? Color.red : Color.secondary)
            }
            .buttonStyle(.plain)
            .help("Mute / unmute")
            Slider(value: volumeBinding, in: 0...1)
                .controlSize(.small)
                .frame(width: 110)
            Text("\(Int((model.volume(for: app) * 100).rounded()))%")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
        }
        .padding(.vertical, 2)
    }

    private var icon: some View {
        Group {
            if let img = app.icon {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.high)
            } else {
                Image(systemName: "app.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
