// Tactus · BassDetector.swift
//
// Turns audio into rumble: filters out everything above the bass, follows its loudness, and spots hits
// (a kick drum, an explosion). Pure logic, used by the games module's audio rumble and the tests.

import Foundation

public struct BassReading: Equatable, Sendable {
    /// How strong the bass is right now, 0…1, relative to the recent average (so quiet and loud mixes both work).
    public var level: Double
    /// True when the bass jumps well above its recent average: a hit.
    public var onset: Bool
}

public final class BassDetector {
    public let sampleRate: Double
    /// Below this loudness (RMS of the filtered signal), it counts as silence.
    public var floor: Double = 0.004

    private let a: Float              // low-pass coefficient
    private var y1: Float = 0, y2: Float = 0
    private var envelope = 0.0        // fast follower
    private var average = 0.0         // slow follower (about 1.5 s)
    private var sinceOnset = 1.0      // seconds since the last hit
    private var armed = true          // a new hit counts only after the last one has died down

    public init(sampleRate: Double, cutoff: Double = 150) {
        self.sampleRate = sampleRate
        a = Float(1 - exp(-2 * Double.pi * cutoff / sampleRate))
    }

    /// Process one block of mono samples (any length; 5–20 ms blocks work best).
    public func process(_ samples: UnsafeBufferPointer<Float>) -> BassReading {
        guard !samples.isEmpty else { return BassReading(level: 0, onset: false) }
        var sum: Float = 0
        for x in samples {
            y1 += a * (x - y1)        // two one-pole low-passes in a row: a gentle 12 dB/octave slope
            y2 += a * (y1 - y2)
            sum += y2 * y2
        }
        let rms = Double((sum / Float(samples.count)).squareRoot())
        let dt = Double(samples.count) / sampleRate
        // Fast rise, slower fall, so hits feel crisp but the rumble doesn't chatter.
        let k = rms > envelope ? min(1, dt / 0.005) : min(1, dt / 0.12)
        envelope += (rms - envelope) * k
        average += (envelope - average) * min(1, dt / 1.5)
        sinceOnset += dt

        guard envelope > floor else { return BassReading(level: 0, onset: false) }
        let level = min(1, max(0, (envelope - floor) / max(average * 2.5, floor * 4)))
        if !armed && envelope < max(average * 1.2, floor * 2) { armed = true }
        let onset = armed && envelope > average * 1.8 && envelope > floor * 3 && sinceOnset > 0.12
        if onset { sinceOnset = 0; armed = false }
        return BassReading(level: level, onset: onset)
    }

    public func process(_ samples: [Float]) -> BassReading {
        samples.withUnsafeBufferPointer { process($0) }
    }
}
