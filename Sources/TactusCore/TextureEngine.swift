// Tactus · TextureEngine.swift
//
// Feeling a picture: the texture logic, kept apart from the Mac-only code so it can be tested anywhere.
//
// A texture is a pattern laid out in space. A finger sliding over it turns that pattern into vibration over
// time: the faster the finger, the higher the frequency. This file samples the image along the path the
// pointer took since the last tick and decides what the motor should play next.
//
//   Edges mode     every sharp light/dark step the pointer crosses is a ridge. Slow strokes give one click
//                  per ridge; fast strokes over many ridges fuse into a buzz whose pitch follows the
//                  ridge rate. Contrast sets strength.
//   Darkness mode  dark areas are rough (like grit), light areas are smooth. Darkness sets strength, and
//                  speed over a fixed grain size sets pitch.
//
// Nothing vibrates while the pointer is still, as with a real surface.

import Foundation

/// A grayscale copy of the image: 0 is black, 1 is white. Row 0 is the top of the image.
public struct LumaMap {
    public let width: Int
    public let height: Int
    public var data: [Float]

    public init(width: Int, height: Int, data: [Float]) {
        precondition(width > 0 && height > 0 && data.count == width * height)
        self.width = width
        self.height = height
        self.data = data
    }

    /// Nearest pixel, with positions outside the image clamped to its edge.
    public func at(_ x: Double, _ y: Double) -> Float {
        let xi = min(width - 1, max(0, Int(x.rounded(.down))))
        let yi = min(height - 1, max(0, Int(y.rounded(.down))))
        return data[yi * width + xi]
    }
}

public struct Point2: Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

public enum TextureMode: Int, Sendable { case edges = 1, darkness = 2 }

public enum HapticKind: String, Sendable { case buzz, click }

/// One thing for the motor to play: a sine tone at `hz`, strength `level` (0…1), lasting `ms`.
public struct Haptic: Sendable {
    public var kind: HapticKind
    public var hz: Double
    public var level: Double
    public var ms: Double
}

/// The settings a person can change while it runs.
public struct TextureSettings: Sendable {
    public var mode: TextureMode = .edges
    /// Overall strength, 0…1.
    public var gain = 0.8
    /// The luminance step (0…1) that counts as a ridge in Edges mode.
    public var edgeStep: Float = 0.12
    /// Grain spacing in screen points for Darkness mode.
    public var grainPoints = 3.0
    /// Target length of one actuation, in ms.
    public var tickMS = 10.0
    public init() {}
}

/// What happened on one tick, for the on-screen readout.
public struct TickReport: Sendable {
    public var haptic: Haptic?
    public var speed = 0.0        // screen points per second
    public var ridgeHz = 0.0      // ridge periods crossed per second (Edges mode)
    public var darkness = 0.0     // mean darkness along the path (0…1)
    public init() {}
}

public final class TextureEngine {
    public init() {}

    // Fixed limits. The fingertip feels vibration best from about 65 to 400 Hz (peak near 250 Hz), and the
    // motor is weak below about 100 Hz, so tones stay in 60…400 Hz.
    let minHz = 60.0
    let maxHz = 400.0
    /// Below this ridge rate, ridges are played one click at a time rather than as a buzz.
    let fuseHz = 50.0
    /// Each click is two cycles of this tone (about 11 ms).
    let clickHz = 180.0
    /// How far back the ridge rate looks, in seconds. Long enough to steady the rate, short enough to follow
    /// a change of speed.
    let window = 0.04
    /// Movement smaller than this (in screen points per tick) counts as standing still.
    let stillPoints = 0.25

    private var reference: Float?
    private var history: [(dt: Double, edges: Int, contrast: Double)] = []
    /// Once buzzing, keep buzzing until the ridge rate falls 20% below `fuseHz`, so it doesn't flicker
    /// between clicks and buzz near the boundary.
    private var buzzing = false

    /// Forget the path: call when the finger lifts or the pointer leaves the image.
    public func reset() {
        reference = nil
        history.removeAll()
        buzzing = false
    }

    /// One tick. `a` and `b` are the pointer's previous and current positions in image pixels,
    /// `pixelsPerPoint` converts image pixels to screen points, `dt` is the time between them in seconds.
    public func step(map: LumaMap, from a: Point2, to b: Point2, pixelsPerPoint: Double, dt: Double,
              settings s: TextureSettings) -> TickReport {
        var report = TickReport()
        guard dt > 0, pixelsPerPoint > 0 else { return report }

        let dx = b.x - a.x, dy = b.y - a.y
        let points = (dx * dx + dy * dy).squareRoot() / pixelsPerPoint
        report.speed = points / dt

        // Sample about once per screen point along the path (a fast flick is capped at 4000 samples).
        let n = min(4000, max(1, Int(points.rounded(.up))))
        var edges = 0
        var contrast = 0.0
        var dark = 0.0
        for i in 1...n {
            let f = Double(i) / Double(n)
            let lum = map.at(a.x + dx * f, a.y + dy * f)
            dark += Double(1 - lum)
            // A ridge is a step of at least `edgeStep` from the last ridge's level (a Schmitt trigger, so
            // small noise and smooth shading don't count).
            if let ref = reference {
                let d = abs(lum - ref)
                if d >= s.edgeStep { edges += 1; contrast += Double(d); reference = lum }
            } else {
                reference = lum
            }
        }
        report.darkness = dark / Double(n)

        history.append((dt, edges, contrast))
        var span = 0.0, winEdges = 0, winContrast = 0.0
        var keep = 0
        for h in history.reversed() {
            if span >= window { break }
            span += h.dt; winEdges += h.edges; winContrast += h.contrast; keep += 1
        }
        history.removeFirst(history.count - keep)

        // A black-and-white grating has two ridges (dark-to-light and back) per period.
        report.ridgeHz = span > 0 ? Double(winEdges) / span / 2 : 0

        guard points >= stillPoints else { buzzing = false; return report }

        switch s.mode {
        case .edges:
            buzzing = report.ridgeHz >= (buzzing ? 0.8 * fuseHz : fuseHz)
            if buzzing {
                let hz = min(maxHz, max(minHz, report.ridgeHz))
                let c = winEdges > 0 ? winContrast / Double(winEdges) : 0
                report.haptic = Haptic(kind: .buzz, hz: hz, level: level(s.gain * (0.3 + 0.7 * c)),
                                       ms: wholeCycles(hz, s.tickMS))
            } else if edges > 0 {
                let c = contrast / Double(edges)
                report.haptic = Haptic(kind: .click, hz: clickHz, level: level(s.gain * (0.3 + 0.7 * c)),
                                       ms: 2000 / clickHz)
            }
        case .darkness:
            guard report.darkness >= 0.08 else { break }
            let hz = min(maxHz, max(minHz, report.speed / max(0.5, s.grainPoints)))
            report.haptic = Haptic(kind: .buzz, hz: hz, level: level(s.gain * report.darkness),
                                   ms: wholeCycles(hz, s.tickMS))
        }
        return report
    }

    private func level(_ x: Double) -> Double { min(1, max(0, x)) }

    /// A length close to `tickMS` that holds a whole number of cycles (at least one), so each actuation ends
    /// where the next begins without a click.
    public func wholeCycles(_ hz: Double, _ tickMS: Double) -> Double {
        max(1, (tickMS / 1000 * hz).rounded()) / hz * 1000
    }
}
