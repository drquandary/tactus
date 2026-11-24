// Tactus · MIDI.swift
//
// MIDI bytes to events, and MIDI clock to beats. Pure logic, used by the music module and the tests.

import Foundation

public enum MIDIEvent: Equatable, Sendable {
    case noteOn(channel: UInt8, note: UInt8, velocity: UInt8)
    case noteOff(channel: UInt8, note: UInt8)
    case controlChange(channel: UInt8, controller: UInt8, value: UInt8)
    case clock, start, stop, continuePlayback
    case songPosition(UInt16)   // in sixteenth notes
}

/// Turns a stream of MIDI bytes into events. Handles running status, real-time bytes in the middle of other
/// messages, and skips system exclusive data.
public struct MIDIParser {
    private var status: UInt8 = 0
    private var data: [UInt8] = []
    private var inSysex = false

    public init() {}

    public mutating func feed<S: Sequence>(_ bytes: S) -> [MIDIEvent] where S.Element == UInt8 {
        var out: [MIDIEvent] = []
        for b in bytes {
            if b >= 0xF8 {   // real-time: can appear anywhere, doesn't disturb running status
                switch b {
                case 0xF8: out.append(.clock)
                case 0xFA: out.append(.start)
                case 0xFB: out.append(.continuePlayback)
                case 0xFC: out.append(.stop)
                default: break
                }
                continue
            }
            if b == 0xF0 { inSysex = true; continue }
            if b == 0xF7 { inSysex = false; continue }
            if inSysex { continue }
            if b & 0x80 != 0 {   // a new status byte
                status = b
                data.removeAll(keepingCapacity: true)
                continue
            }
            guard status != 0 else { continue }   // data with no status yet
            data.append(b)
            if data.count == expectedLength(status) {
                if let e = event(status, data) { out.append(e) }
                data.removeAll(keepingCapacity: true)
                if status >= 0xF0 { status = 0 }   // system common messages don't set running status
            }
        }
        return out
    }

    private func expectedLength(_ s: UInt8) -> Int {
        switch s & 0xF0 {
        case 0xC0, 0xD0: return 1
        case 0xF0:
            switch s { case 0xF2: return 2; case 0xF1, 0xF3: return 1; default: return 0 }
        default: return 2
        }
    }

    private func event(_ s: UInt8, _ d: [UInt8]) -> MIDIEvent? {
        let ch = s & 0x0F
        switch s & 0xF0 {
        case 0x90: return d[1] == 0 ? .noteOff(channel: ch, note: d[0]) : .noteOn(channel: ch, note: d[0], velocity: d[1])
        case 0x80: return .noteOff(channel: ch, note: d[0])
        case 0xB0: return .controlChange(channel: ch, controller: d[0], value: d[1])
        default:
            if s == 0xF2 { return .songPosition(UInt16(d[0]) | UInt16(d[1]) << 7) }
            return nil
        }
    }
}

public enum BeatTick: Equatable, Sendable { case downbeat, beat }

/// Counts MIDI clock (24 pulses per quarter note) into beats and bars.
public struct BeatCounter {
    public var beatsPerBar: Int
    public private(set) var clocks = 0
    public private(set) var running = true

    public init(beatsPerBar: Int = 4) { self.beatsPerBar = max(1, beatsPerBar) }

    /// The beat this event lands on, if any. Clock received while stopped is ignored.
    public mutating func handle(_ e: MIDIEvent) -> BeatTick? {
        switch e {
        case .start: clocks = 0; running = true
        case .continuePlayback: running = true
        case .stop: running = false
        case .songPosition(let sixteenths): clocks = Int(sixteenths) * 6
        case .clock:
            guard running else { return nil }
            defer { clocks += 1 }
            if clocks % 24 == 0 { return (clocks / 24) % beatsPerBar == 0 ? .downbeat : .beat }
        default: break
        }
        return nil
    }
}

/// Which pattern a drum note plays (General MIDI drum map), if it's one Tactus knows.
public enum DrumMap {
    public static func patternName(note: UInt8) -> String? {
        switch note {
        case 35, 36: return "kick"
        case 37, 38, 39, 40: return "snare"
        case 42, 44, 46: return "hat"
        case 49, 52, 55, 57: return "bump"   // crashes
        default: return nil
        }
    }

    /// A note's pitch folded by octaves into the range the fingertip feels best (60…400 Hz).
    public static func feelableHz(note: UInt8) -> Double {
        var f = 440 * pow(2, (Double(note) - 69) / 12)
        while f > 400 { f /= 2 }
        while f < 60 { f *= 2 }
        return f
    }
}
