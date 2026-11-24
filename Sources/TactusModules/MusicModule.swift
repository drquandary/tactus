// Tactus · MusicModule.swift
//
// Feel music through the trackpad, for producers, performers and deaf or hard-of-hearing musicians:
//
//   Beats from MIDI clock  a tick on every beat and a bump on each bar's downbeat, following your DAW's tempo
//                          (send MIDI clock to the "Tactus" MIDI destination, or from any connected device)
//   Drum hits              kick, snare, hats and crashes from General MIDI drum notes become thud, hit, tick
//   Notes                  other notes become pulses whose pitch follows the note (folded into the range
//                          fingertips feel best) and whose strength follows velocity
//   Metronome              a built-in click at a set tempo, for practice with no DAW running
//
// Tactus appears as a MIDI destination called "Tactus" and also listens to every MIDI source on the Mac.

import AppKit
import CoreMIDI
import TactusCore

public final class MusicModule: TactusModule {
    public let id = "music"
    public let title = "Music"
    public let summary = "MIDI clock beats, drum hits and notes you can feel; a metronome"
    public private(set) var isRunning = false

    enum Feature: String, CaseIterable {
        case clock = "Beats from MIDI clock"
        case drums = "Drum hits"
        case notes = "Other notes as pulses"
        case metronome = "Metronome"
    }
    private let flags = Flags<Feature>([.clock, .drums])
    private var client = MIDIClientRef()
    private var inPort = MIDIPortRef()
    private var destination = MIDIEndpointRef()
    private var connected = Set<MIDIEndpointRef>()
    private let lock = NSLock()
    private var parsers: [MIDIEndpointRef: MIDIParser] = [:]
    private var beats = BeatCounter()
    private var metronome: Thread?
    private var metronomeOn = false
    public private(set) var bpm = 100.0
    public private(set) var eventsReceived = 0
    public private(set) var midiProblem: String?

    public init() {}

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        setUpMIDI()
        if flags.contains(.metronome) { startMetronome() }
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        stopMetronome()
        for src in connected { MIDIPortDisconnectSource(inPort, src) }
        connected.removeAll()
        if destination != 0 { MIDIEndpointDispose(destination); destination = 0 }
        if inPort != 0 { MIDIPortDispose(inPort); inPort = 0 }
        if client != 0 { MIDIClientDispose(client); client = 0 }
    }

    public func menuItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = Feature.allCases.map { f in
            ClosureMenuItem(f == .metronome ? "Metronome (\(Int(bpm)) BPM)" : f.rawValue, checked: flags.contains(f)) { [weak self] in
                guard let self else { return }
                self.flags.toggle(f)
                if f == .metronome { self.flags.contains(.metronome) ? self.startMetronome() : self.stopMetronome() }
            }
        }
        items.append(ClosureMenuItem("Faster (+5 BPM)") { [weak self] in self?.setBPM((self?.bpm ?? 100) + 5) })
        items.append(ClosureMenuItem("Slower (−5 BPM)") { [weak self] in self?.setBPM((self?.bpm ?? 100) - 5) })
        let status = midiProblem ?? "MIDI: \(connected.count) source\(connected.count == 1 ? "" : "s") + \"Tactus\" destination, \(eventsReceived) events"
        items.append(ClosureMenuItem(status, enabled: false))
        return items
    }

    public func setBPM(_ v: Double) { lock.lock(); bpm = min(300, max(30, v)); lock.unlock() }

    // MARK: MIDI

    private func setUpMIDI() {
        var status = MIDIClientCreateWithBlock("Tactus" as CFString, &client) { [weak self] note in
            if note.pointee.messageID == .msgSetupChanged { DispatchQueue.main.async { self?.connectSources() } }
        }
        guard status == noErr else { midiProblem = "MIDI unavailable (error \(status))"; return }
        status = MIDIInputPortCreateWithProtocol(client, "Tactus input" as CFString, ._1_0, &inPort) { [weak self] list, src in
            self?.receive(list, from: MIDIEndpointRef(UInt(bitPattern: src)))
        }
        guard status == noErr else { midiProblem = "MIDI input unavailable (error \(status))"; return }
        status = MIDIDestinationCreateWithProtocol(client, "Tactus" as CFString, ._1_0, &destination) { [weak self] list, _ in
            self?.receive(list, from: 0)
        }
        if status != noErr { midiProblem = "couldn't create the Tactus MIDI destination (error \(status))" }
        connectSources()
    }

    private func connectSources() {
        guard inPort != 0 else { return }
        for i in 0..<MIDIGetNumberOfSources() {
            let src = MIDIGetSource(i)
            guard src != 0, !connected.contains(src) else { continue }
            // Pass the source as the connection's refCon so we know which parser to use.
            let ref = UnsafeMutableRawPointer(bitPattern: UInt(src))
            if MIDIPortConnectSource(inPort, src, ref) == noErr { connected.insert(src) }
        }
    }

    /// MIDI 1.0 events arrive as Universal MIDI Packets; turn each back into MIDI bytes for the parser.
    private func receive(_ list: UnsafePointer<MIDIEventList>, from src: MIDIEndpointRef) {
        var bytes: [UInt8] = []
        for packet in list.unsafeSequence() {
            let count = min(64, Int(packet.pointee.wordCount))   // `words` holds 64; longer packets are sysex
            withUnsafeBytes(of: packet.pointee.words) { raw in
                let words = raw.bindMemory(to: UInt32.self)
                var i = 0
                while i < count {
                    let w = words[i]
                    let type = w >> 28
                    let status = UInt8(w >> 16 & 0xFF), d1 = UInt8(w >> 8 & 0x7F), d2 = UInt8(w & 0x7F)
                    switch type {
                    case 0x1:   // system real-time and common
                        bytes.append(status)
                        if status == 0xF2 { bytes += [d1, d2] } else if status == 0xF1 || status == 0xF3 { bytes.append(d1) }
                    case 0x2:   // MIDI 1.0 channel voice
                        bytes.append(status)
                        bytes.append(d1)
                        if status & 0xF0 != 0xC0 && status & 0xF0 != 0xD0 { bytes.append(d2) }
                    default:
                        break   // sysex and MIDI 2.0 packets: not used
                    }
                    i += type >= 0x3 && type <= 0x5 ? (type == 0x5 ? 4 : 2) : 1
                }
            }
        }
        lock.lock()
        var parser = parsers[src] ?? MIDIParser()
        let events = parser.feed(bytes)
        parsers[src] = parser
        eventsReceived += events.count
        lock.unlock()
        for e in events { handle(e) }
    }

    private func handle(_ e: MIDIEvent) {
        lock.lock(); let tick = beats.handle(e); lock.unlock()
        if let tick, flags.contains(.clock) {
            Haptics.shared.play(tick == .downbeat ? "downbeat" : "beat")
        }
        guard case .noteOn(let ch, let note, let velocity) = e else { return }
        let level = Double(velocity) / 127
        if flags.contains(.drums), let drum = DrumMap.patternName(note: note), ch == 9 || !flags.contains(.notes) {
            Haptics.shared.play(drum, level: 0.4 + 0.6 * level)
        } else if flags.contains(.notes) {
            Haptics.shared.play(Pulse(hz: DrumMap.feelableHz(note: note), ms: 25, level: 0.3 + 0.7 * level))
        }
    }

    // MARK: Metronome

    private func startMetronome() {
        guard metronome == nil, isRunning else { return }
        metronomeOn = true
        let t = Thread { [weak self] in
            var beat = 0
            var next = Clock.now()
            while let self, self.metronomeOn {
                Haptics.shared.play(beat % 4 == 0 ? "downbeat" : "beat")
                beat += 1
                self.lock.lock(); let interval = 60 / self.bpm; self.lock.unlock()
                next += interval
                Clock.wait(until: next)
            }
        }
        t.qualityOfService = .userInteractive
        metronome = t
        t.start()
    }

    private func stopMetronome() { metronomeOn = false; metronome = nil }
}
