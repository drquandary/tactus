// Tactus · Pattern.swift
//
// A pattern is a short sequence of pulses. Each pulse is a sine tone on the trackpad's motor: a frequency, a
// length and a strength, then an optional silence before the next pulse.
//
// Patterns have names (`bump`, `tick`, `heartbeat`…) or can be written out as text:
//
//     "hz:ms:level[/gap], …"      e.g. "230:9:0.5/55, 230:9:0.5" is two light ticks 55 ms apart
//
// The fingertip feels vibration best between about 65 and 400 Hz (most strongly near 250 Hz). The motor
// itself can play from about 50 Hz to 4 kHz, but above 400 Hz you mostly hear it rather than feel it.

import Foundation

public struct Pulse: Equatable, Sendable {
    public var hz: Double
    public var ms: Double
    public var level: Double
    public var gapMS: Double

    public init(hz: Double, ms: Double, level: Double, gapMS: Double = 0) {
        self.hz = min(4000, max(40, hz))
        self.ms = min(2000, max(1, ms))
        self.level = min(1, max(0, level))
        self.gapMS = min(5000, max(0, gapMS))
    }

    /// The length rounded to a whole number of cycles (at least one), so the tone ends where it started and
    /// the motor doesn't click.
    public var wholeCycleMS: Double { max(1, (ms / 1000 * hz).rounded()) / hz * 1000 }
}

public struct Pattern: Equatable, Sendable {
    public var pulses: [Pulse]

    public init(_ pulses: [Pulse]) { self.pulses = pulses }

    /// Total length including gaps, in ms.
    public var durationMS: Double { pulses.reduce(0) { $0 + $1.wholeCycleMS + $1.gapMS } }

    /// The same pattern with every pulse's strength multiplied by `k` (clamped to 0…1).
    public func scaled(_ k: Double) -> Pattern {
        Pattern(pulses.map { Pulse(hz: $0.hz, ms: $0.ms, level: $0.level * k, gapMS: $0.gapMS) })
    }

    // MARK: Named patterns

    private static func p(_ hz: Double, _ ms: Double, _ level: Double, _ gap: Double = 0) -> Pulse {
        Pulse(hz: hz, ms: ms, level: level, gapMS: gap)
    }

    /// The built-in patterns. Modules and the bridge refer to these by name.
    public static let library: [String: Pattern] = [
        // General
        "tick": Pattern([p(230, 9, 0.5)]),
        "click": Pattern([p(300, 7, 0.4)]),
        "bump": Pattern([p(150, 20, 1.0)]),
        "thud": Pattern([p(80, 37.5, 1.0)]),
        "double": Pattern([p(230, 9, 0.6, 55), p(230, 9, 0.6)]),
        "triple": Pattern([p(230, 9, 0.6, 45), p(230, 9, 0.6, 45), p(230, 9, 0.6)]),
        "heartbeat": Pattern([p(70, 43, 0.9, 120), p(70, 43, 0.6)]),
        "success": Pattern([p(200, 10, 0.6, 60), p(300, 10, 0.8)]),
        "error": Pattern([p(120, 25, 1.0, 70), p(120, 25, 1.0, 70), p(120, 25, 1.0)]),
        "alert": Pattern([p(250, 100, 0.9)]),
        "buzz": Pattern([p(180, 200, 0.7)]),
        "rumble": Pattern([p(60, 300, 0.9)]),
        "rise": Pattern([p(100, 20, 0.5), p(150, 20, 0.6), p(220, 20, 0.7), p(320, 20, 0.8)]),
        "fall": Pattern([p(320, 20, 0.8), p(220, 20, 0.7), p(150, 20, 0.6), p(100, 20, 0.5)]),
        // Interface cues (signals and access modules)
        "snap": Pattern([p(150, 20, 1.0)]),
        "edge": Pattern([p(100, 30, 0.8)]),
        "button": Pattern([p(230, 9, 0.5)]),
        "close": Pattern([p(230, 9, 0.6, 55), p(230, 9, 0.6)]),
        "link": Pattern([p(260, 7, 0.45, 35), p(330, 7, 0.45)]),
        "field": Pattern([p(120, 40, 0.35)]),
        "toggle-on": Pattern([p(280, 12, 0.8)]),
        "toggle-off": Pattern([p(120, 12, 0.5)]),
        "slider": Pattern([p(150, 10, 0.4), p(220, 10, 0.5), p(300, 10, 0.6)]),
        "menu": Pattern([p(200, 10, 0.35)]),
        "heading": Pattern([p(230, 9, 0.6, 45), p(230, 9, 0.6, 45), p(230, 9, 0.6)]),
        "image": Pattern([p(90, 33, 0.5)]),
        "popup": Pattern([p(230, 9, 0.5, 40), p(150, 12, 0.5)]),
        // Music
        "beat": Pattern([p(230, 9, 0.7)]),
        "downbeat": Pattern([p(150, 20, 1.0)]),
        "kick": Pattern([p(80, 37.5, 1.0)]),
        "snare": Pattern([p(180, 22, 0.9)]),
        "hat": Pattern([p(400, 5, 0.3)]),
        // Games
        "hit": Pattern([p(140, 30, 1.0)]),
        "explosion": Pattern([p(50, 120, 1.0), p(70, 200, 0.6)]),
        "pickup": Pattern([p(260, 8, 0.6, 30), p(340, 10, 0.8)]),
        "damage": Pattern([p(90, 60, 1.0, 40), p(90, 40, 0.6)]),
    ]

    public static var names: [String] { library.keys.sorted() }

    public static func named(_ name: String) -> Pattern? { library[name.lowercased()] }

    /// Parses "hz:ms:level[/gap], …". Returns nil if any part is malformed.
    public static func parse(_ spec: String) -> Pattern? {
        var pulses: [Pulse] = []
        for part in spec.split(separator: ",") {
            let piece = part.trimmingCharacters(in: .whitespaces)
            guard !piece.isEmpty else { continue }
            let halves = piece.split(separator: "/", maxSplits: 1).map(String.init)
            let fields = halves[0].split(separator: ":").map { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard fields.count == 3, let hz = fields[0], let ms = fields[1], let level = fields[2] else { return nil }
            var gap = 0.0
            if halves.count == 2 {
                guard let g = Double(halves[1].trimmingCharacters(in: .whitespaces)) else { return nil }
                gap = g
            }
            pulses.append(Pulse(hz: hz, ms: ms, level: level, gapMS: gap))
        }
        return pulses.isEmpty ? nil : Pattern(pulses)
    }
}
