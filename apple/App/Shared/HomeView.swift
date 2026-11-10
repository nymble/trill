// SPDX-License-Identifier: GPL-3.0-only
//
// First screen: what Trillium is, whether an instrument is plugged in, a
// one-tap Connect, and once connected a plain description of the current
// sound. Ports, protocol details and the full editor live under Settings.

import SwiftUI
import TrillKit

struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14).fill(.quaternary.opacity(0.5)))
    }
}

struct HomeView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 14) {
                        TrilliumMark(size: 56)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Trillium").font(.title.weight(.semibold))
                            Text("Motion and touch to play any synth or music app over USB MIDI.")
                                .foregroundStyle(.secondary)
                        }
                    }
                    ConnectionCard()
                    if model.session.isReady { NowPlayingCard() }
                    Text("Trillium plays straight into your music app over USB. You don't need this app open while you play; use it to pick a sound, watch the sensors or fine-tune.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .padding()
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Home")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
    }
}

struct ConnectionCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Card {
            if let e = model.midiError {
                Label("MIDI is unavailable: \(e)", systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            } else {
                switch model.session.phase {
                case .ready:
                    connected
                case .handshaking:
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Connecting to Trillium…")
                    }
                case let .failed(why):
                    Label("Couldn't connect", systemImage: "xmark.octagon").font(.headline).foregroundStyle(.red)
                    Text(why).font(.callout).foregroundStyle(.secondary)
                    Button("Try again") { model.connectToDetected() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.trillDetected)
                case .disconnected:
                    if model.trillDetected { found } else { plugIn }
                }
            }
        }
    }

    private var plugIn: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Connect your Trillium", systemImage: "cable.connector").font(.headline)
            Text("Plug the instrument into this \(PresetsView.deviceWord) with a USB cable. It appears here as soon as it's detected.")
                .font(.callout).foregroundStyle(.secondary)
            #if os(iOS)
            Text("On iPhone or iPad, use a USB-C cable or a Lightning-to-USB camera adapter.")
                .font(.caption).foregroundStyle(.secondary)
            #endif
        }
    }

    private var found: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Trillium found", systemImage: "checkmark.circle").font(.headline).foregroundStyle(.green)
            Text("Connect to choose sounds, watch the sensors and change settings. Playing works without connecting.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("Connect") { model.connectToDetected() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                Toggle("Connect automatically", isOn: Binding(get: { model.autoConnect }, set: { model.autoConnect = $0 }))
                    .font(.callout)
            }
        }
    }

    private var connected: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Connected", systemImage: "checkmark.circle.fill").font(.headline).foregroundStyle(.green)
                Spacer()
                Button("Disconnect") { model.disconnectConfig() }.controlSize(.small)
            }
            if let h = model.session.hello {
                Text("Firmware \(h.firmwareString)").font(.caption).foregroundStyle(.secondary)
            }
            if model.session.deviceRestarted {
                Text("Trillium restarted since you last connected, so it went back to its default sound.")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }
}

struct NowPlayingCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let cfg = model.session.acknowledged ?? model.draft
        let mode = model.session.supportsConfigPages ? SensorMode(rawValue: cfg[.mode]) ?? .touch : .touch
        Card {
            HStack(alignment: .firstTextBaseline) {
                Text("Current sound").font(.headline)
                Spacer()
                Text(model.activePresetName ?? "Custom").foregroundStyle(.secondary)
            }
            Label(mode.name, systemImage: mode.symbol).font(.title3.weight(.medium))
            Text(mode.howItPlays).font(.callout).foregroundStyle(.secondary)
            Divider()
            RoutingList(lines: MappingSummary.lines(cfg, pages: model.session.supportedPages))
            HStack {
                Button("Change sound") { model.tab = .presets }.buttonStyle(.borderedProminent)
                Button("Edit…") { model.openMapping() }
                Spacer()
                Button {
                    model.perform(.panic)
                } label: { Label("All notes off", systemImage: "speaker.slash") }
                    .help("Sends All Notes Off and resets controllers.")
                Button {
                    model.perform(.recalibrateGyro)
                } label: { Label("Recalibrate", systemImage: "scope") }
                    .help("Hold Trillium still for about a second.")
            }
            .controlSize(.small)
            Text("Changes last until Trillium is unplugged. Save sounds you like as presets.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// "input → output" rows for a configuration.
struct RoutingList: View {
    let lines: [RoutingLine]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(lines, id: \.self) { l in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: l.symbol).frame(width: 20).foregroundStyle(.tint)
                    Text(l.input).frame(minWidth: 120, alignment: .leading)
                    Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary)
                    Text(l.output).foregroundStyle(.secondary)
                }
                .font(.callout)
            }
            if lines.isEmpty { Text("Nothing is mapped.").foregroundStyle(.secondary) }
        }
    }
}
