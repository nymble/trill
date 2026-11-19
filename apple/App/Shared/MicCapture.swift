// SPDX-License-Identifier: GPL-3.0-only
//
// Microphone test path: open the board's PCM CDC port, decode TRPC frames,
// feed a live level/waveform chart, and (macOS only) play the signal
// through the system output. Not part of any instrument or configuration.

import Foundation
import SwiftUI
import TrillKit
#if os(macOS)
import AVFoundation
#endif

/// Live state for the Sensors microphone test panel.
@MainActor
final class MicCapture: ObservableObject {
    @Published var wanted = false
    @Published var playthrough = false
    @Published var level: Float = 0
    @Published var waveform: [Float] = []
    @Published var status = ""
    @Published var sampleRate: Int = 0
    @Published var frames = 0
    @Published var dropped = 0

    private var waveformRing: [Float] = Array(repeating: 0, count: 240)
    private var waveformCount = 0

#if os(macOS)
    private var openGeneration = 0
    private var source: DispatchSourceRead?
    private let reader = ReaderState()
    private var player: MicPlayer?
    private let queue = DispatchQueue(label: "trillium.mic-pcm")
#endif

    var supportedOnThisPlatform: Bool {
#if os(macOS)
        true
#else
        false
#endif
    }

    func setWanted(_ on: Bool, start: () -> Bool, stop: () -> Void) {
        wanted = on
        if on {
            guard start() else {
                wanted = false
                status = "The connected firmware does not offer microphone test capture."
                return
            }
            beginReading()
        } else {
            stop()
            endReading()
            status = ""
            level = 0
        }
    }

    func setPlaythrough(_ on: Bool) {
        playthrough = on
#if os(macOS)
        if !on { player?.stop(); player = nil }
#endif
    }

    func disconnect() {
        if wanted {
            wanted = false
            endReading()
            level = 0
            status = ""
        }
    }

    private func beginReading() {
#if os(macOS)
        endReading()
        reader.parser = PcmStream.Parser()
        frames = 0
        dropped = 0
        sampleRate = 0
        guard let path = Self.findPcmPort() else {
            status = "The USB PCM port was not found. Check that the board enumerates as 1209:0003."
            return
        }
        let fd: Int32
        do {
            // Raw mode: the default tty line discipline mangles binary frames.
            fd = try RawSerial.openForReading(path)
        } catch {
            status = "Could not open the USB PCM port (\(error))."
            return
        }
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in
            let data = RawSerial.readAvailable(fd)
            guard !data.isEmpty, let self else { return }
            let frames = self.reader.parser.push(data)
            guard !frames.isEmpty else { return }
            DispatchQueue.main.async { self.apply(frames) }
        }
        src.setCancelHandler { close(fd) }
        source = src
        src.resume()
        status = "Listening on \(path)"
        let generation = openGeneration &+ 1
        openGeneration = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.wanted, self.openGeneration == generation, self.frames == 0 else { return }
            self.status = "No microphone data on \(path) yet. Unplug and reconnect the board, then try again."
        }
#else
        status = "Microphone play-through and the USB PCM port are available in the Mac app."
#endif
    }

    private func endReading() {
#if os(macOS)
        source?.cancel()
        source = nil
        openGeneration &+= 1
        player?.stop()
        player = nil
#endif
    }

#if os(macOS)
    private func apply(_ frames: [PcmStream.Frame]) {
        for f in frames {
            self.frames += 1
            if f.dropped { dropped += 1 }
            sampleRate = Int(f.sampleRate)
            var peak: Float = 0
            var acc: Float = 0
            for s in f.samples {
                let v = Float(s) / 32768
                acc += v * v
                peak = max(peak, abs(v))
            }
            level = peak
            let rms = f.samples.isEmpty ? 0 : sqrt(acc / Float(f.samples.count))
            waveformRing[waveformCount % waveformRing.count] = rms
            waveformCount += 1
            if playthrough {
                if player == nil { player = MicPlayer(sampleRate: Double(f.sampleRate)) }
                player?.schedule(f.samples, sampleRate: Double(f.sampleRate))
            }
        }
        let n = waveformRing.count
        if waveformCount >= n {
            let start = waveformCount % n
            waveform = Array(waveformRing[start..<n]) + Array(waveformRing[..<start])
        } else {
            waveform = Array(waveformRing[..<waveformCount])
        }
    }

    /// The PCM CDC data interface (interface 5 on the six-interface layout).
    static func findPcmPort() -> String? {
        TrilliumUSB.serialPorts().first { $0.role == .microphonePCM }?.path
    }
#endif
}

#if os(macOS)
/// Touched only on `queue`.
private final class ReaderState: @unchecked Sendable {
    var parser = PcmStream.Parser()
}

/// Play 16-bit mono PCM through the default output using AVAudioEngine.
private final class MicPlayer {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var format: AVAudioFormat
    private var started = false

    init?(sampleRate: Double) {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false) else {
            return nil
        }
        self.format = format
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
            node.play()
            started = true
        } catch {
            return nil
        }
    }

    func schedule(_ samples: [Int16], sampleRate: Double) {
        if abs(format.sampleRate - sampleRate) > 0.5,
           let next = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false) {
            engine.disconnectNodeOutput(node)
            engine.connect(node, to: engine.mainMixerNode, format: next)
            format = next
        }
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        buf.frameLength = AVAudioFrameCount(samples.count)
        if let ch = buf.floatChannelData {
            for (i, s) in samples.enumerated() { ch[0][i] = Float(s) / 32768 }
        }
        node.scheduleBuffer(buf)
        if !node.isPlaying { node.play() }
    }

    func stop() {
        node.stop()
        engine.stop()
    }
}
#endif
