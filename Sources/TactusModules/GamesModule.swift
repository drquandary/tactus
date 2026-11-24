// Tactus · GamesModule.swift
//
// Haptics for games, two ways:
//
//   Audio rumble   works with any game (or film, or music) with no changes to it: Tactus listens to the Mac's
//                  sound, keeps only the bass, and turns it into rumble, with a firm thud on every hit or
//                  explosion. Needs Screen & System Audio Recording permission (macOS asks the first time).
//   Bridge         games that want precise effects send them to Tactus (hit, explosion, an engine that
//                  follows RPM…). See the Bridge module and docs/PROTOCOL.md; examples/ has Godot, Unity
//                  and Python.
//
// The menu also has a few effects to try.

import AppKit
import AVFoundation
import ScreenCaptureKit
import TactusCore

public final class GamesModule: TactusModule {
    public let id = "games"
    public let title = "Games"
    public let summary = "Audio rumble from any game's sound; effects for games that use the bridge"
    public var permissions: [TactusPermission] { [.screenRecording] }
    public private(set) var isRunning = false

    private var tap: AudioRumble?
    public var rumbleStrength = 0.8
    public private(set) var problem: String?

    public init() {}

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        guard TactusPermission.screenRecording.granted else {
            problem = "Audio rumble needs Screen & System Audio Recording permission"
            TactusPermission.screenRecording.request()
            return
        }
        problem = nil
        let t = AudioRumble { [weak self] in self?.rumbleStrength ?? 0.8 }
        tap = t
        t.start { [weak self] err in self?.problem = err }
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        tap?.stop(); tap = nil
        Haptics.shared.release("rumble")
    }

    public func menuItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        if let problem { items.append(ClosureMenuItem(problem, enabled: false)) }
        else if isRunning { items.append(ClosureMenuItem(String(format: "Audio rumble on (strength %.1f)", rumbleStrength), enabled: false)) }
        items.append(ClosureMenuItem("Rumble stronger") { [weak self] in self.map { $0.rumbleStrength = min(1, $0.rumbleStrength + 0.1) } })
        items.append(ClosureMenuItem("Rumble weaker") { [weak self] in self.map { $0.rumbleStrength = max(0.1, $0.rumbleStrength - 0.1) } })
        items.append(.separator())
        for name in ["hit", "explosion", "pickup", "damage", "heartbeat"] {
            items.append(ClosureMenuItem("Try “\(name)”") { Haptics.shared.play(name, grace: 2) })
        }
        items.append(ClosureMenuItem("Try an engine revving up") {
            DispatchQueue.global().async {
                for i in 0..<40 {
                    Haptics.shared.hold("engine", hz: 45 + Double(i) * 2.5, level: 0.4 + Double(i) / 80, ttlMS: 120)
                    usleep(50_000)
                }
                Haptics.shared.release("engine")
            }
        })
        return items
    }
}

/// Captures the Mac's sound output (not the microphone) with ScreenCaptureKit and feeds it to a bass detector.
final class AudioRumble: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private let audioQueue = DispatchQueue(label: "tactus.audio", qos: .userInteractive)
    private let videoQueue = DispatchQueue(label: "tactus.audio.video")
    private var detector: BassDetector?
    private let strength: () -> Double

    init(strength: @escaping () -> Double) { self.strength = strength }

    func start(onError: @escaping (String) -> Void) {
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first else { onError("no display to capture audio from"); return }
                let me = content.applications.filter { $0.processID == getpid() }
                let filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])
                let config = SCStreamConfiguration()
                config.capturesAudio = true
                config.excludesCurrentProcessAudio = true
                config.sampleRate = 48000
                config.channelCount = 1
                // The stream must have video too; keep it tiny and slow.
                config.width = 2
                config.height = 2
                config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
                let s = SCStream(filter: filter, configuration: config, delegate: self)
                try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
                try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
                try await s.startCapture()
                stream = s
            } catch {
                onError("audio capture failed: \(error.localizedDescription)")
            }
        }
    }

    func stop() {
        let s = stream
        stream = nil
        Task { try? await s?.stopCapture() }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, buffer.isValid else { return }
        if detector == nil {
            let sr = buffer.formatDescription?.audioStreamBasicDescription?.mSampleRate ?? 48000
            detector = BassDetector(sampleRate: sr)
        }
        guard let detector else { return }
        try? buffer.withAudioBufferList { list, _ in
            guard let first = list.first, let data = first.mData else { return }
            let n = Int(first.mDataByteSize) / MemoryLayout<Float>.size
            let samples = UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: n)
            let r = detector.process(samples)
            let k = strength()
            if r.onset { Haptics.shared.play("thud", level: k, grace: 0) }
            if r.level > 0.05 {
                Haptics.shared.hold("rumble", hz: 50 + 40 * r.level, level: r.level * k * 0.8, ttlMS: 80)
            }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) { self.stream = nil }
}
