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
import IOKit
import IOKit.serial
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
    private var handle: FileHandle?
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
        do {
            let fh = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
            handle = fh
            let fd = fh.fileDescriptor
            let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            src.setEventHandler { [weak self] in
                let available = Int(src.data)
                guard available > 0, let data = try? fh.read(upToCount: max(available, 1)), !data.isEmpty else { return }
                guard let self else { return }
                let frames = self.reader.parser.push(Array(data))
                guard !frames.isEmpty else { return }
                DispatchQueue.main.async { self.apply(frames) }
            }
            src.setCancelHandler { try? fh.close() }
            source = src
            src.resume()
            status = "Listening on \(path)"
        } catch {
            status = "Could not open the USB PCM port."
        }
#else
        status = "Microphone play-through and the USB PCM port are available in the Mac app."
#endif
    }

    private func endReading() {
#if os(macOS)
        source?.cancel()
        source = nil
        handle = nil
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

    /// The PCM CDC data interface is interface 5 on the six-interface layout.
    private static let pcmInterface = 5
    private static let vid = 0x1209
    private static let pids: Set<Int> = [0x0002, 0x0003]

    static func findPcmPort() -> String? {
        let matching = IOServiceMatching(kIOSerialBSDServiceValue)
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &it) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(it) }
        var fallback: String?
        while true {
            let service = IOIteratorNext(it)
            if service == 0 { break }
            defer { IOObjectRelease(service) }
            func prop(_ s: io_object_t, _ k: String) -> Any? {
                IORegistryEntryCreateCFProperty(s, k as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            }
            let path = (prop(service, kIOCalloutDeviceKey) as? String)
                ?? (prop(service, "IOCalloutDevice") as? String)
            guard let path else { continue }
            var parent: io_object_t = 0
            var current = service
            var vid = 0, pid = 0, iface = -1
            // Walk up to the USB device; note the first interface number seen.
            while IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS {
                if current != service { IOObjectRelease(current) }
                current = parent
                if let v = prop(current, "idVendor") as? Int { vid = v }
                if let p = prop(current, "idProduct") as? Int { pid = p }
                if iface < 0, let n = prop(current, "bInterfaceNumber") as? Int { iface = n }
                if vid != 0 && pid != 0 { break }
            }
            if current != service { IOObjectRelease(current) }
            guard vid == Self.vid, Self.pids.contains(pid) else { continue }
            if iface == pcmInterface { return path }
            if fallback == nil { fallback = path }
        }
        return fallback
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
