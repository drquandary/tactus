// Tactus · Haptics.swift
//
// The one place everything plays through. Modules and the bridge hand it patterns, single pulses or steady
// "holds"; it applies the overall strength, checks that a finger is on the trackpad, and plays them in order.
//
//   Haptics.shared.play("bump")                        a named pattern
//   Haptics.shared.play(pattern, level: 0.5)           any pattern, at half strength
//   Haptics.shared.hold("engine", hz: 60, level: 0.4)  a steady vibration, until released or it times out
//   Haptics.shared.release("engine")

import Foundation

public final class Haptics: @unchecked Sendable {
    public static let shared = Haptics()

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "tactus.haptics", qos: .userInteractive)
    private var _gain = 0.8
    private var _requireFinger = true
    private var _paused = false
    private var holds: [String: (hz: Double, level: Double, until: Double)] = [:]
    private var holdThread: Thread?
    private var lastLight = 0.0   // on `queue`

    /// Called with a line for each thing played, when set (for --verbose).
    public var log: ((String) -> Void)?

    private init() {}

    /// Overall strength, 0.1…1.
    public var gain: Double {
        get { lock.lock(); defer { lock.unlock() }; return _gain }
        set { lock.lock(); _gain = min(1, max(0.1, newValue)); lock.unlock() }
    }
    /// Only play while a finger is on the trackpad (or just after it lifts). Vibration with no finger on the
    /// pad can't be felt, only heard.
    public var requireFinger: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _requireFinger }
        set { lock.lock(); _requireFinger = newValue; lock.unlock() }
    }
    public var paused: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _paused }
        set { lock.lock(); _paused = newValue; lock.unlock() }
    }

    /// True if something played now would be felt: a finger is on the pad, or left it within `grace` seconds.
    public func fingerAllows(grace: Double = 0.3) -> Bool {
        if paused { return false }
        if !requireFinger { return true }
        let pad = Trackpad.shared
        if !pad.touchWorking { return true }   // no finger data at all: don't block everything
        return pad.fingerDown || Clock.now() - pad.lastFingerTime <= grace
    }

    // MARK: One-shot patterns

    /// Plays a named pattern. Unknown names are ignored.
    public func play(_ name: String, level: Double = 1, grace: Double = 0.3, light: Bool = false) {
        guard let p = Pattern.named(name) else { return }
        play(p, level: level, grace: grace, light: light, label: name)
    }

    /// Plays a pattern. `light` marks frequent, low-priority cues (hover ticks, scroll ticks): those are
    /// dropped if one played less than 30 ms ago, so a fast flick doesn't become a buzz.
    public func play(_ p: Pattern, level: Double = 1, grace: Double = 0.3, light: Bool = false, label: String = "pattern") {
        guard fingerAllows(grace: grace) else { return }
        let k = min(1, max(0, level)) * gain
        queue.async { [self] in
            if light {
                let t = Clock.now()
                guard t - lastLight >= 0.03 else { return }
                lastLight = t
            }
            log?(String(format: "play %@ ×%.2f", label, k))
            for pulse in p.pulses {
                let start = Clock.now()
                Trackpad.shared.playTone(hz: pulse.hz, ms: pulse.ms, level: pulse.level * k)
                Clock.wait(until: start + (pulse.wholeCycleMS + pulse.gapMS) / 1000)
            }
        }
    }

    public func play(_ pulse: Pulse, grace: Double = 0.3) { play(Pattern([pulse]), grace: grace, label: "pulse") }

    // MARK: Holds (steady vibration)

    /// Starts or updates a steady vibration from `source`. It stops on `release`, or after `ttlMS` without
    /// being refreshed. When several sources hold at once, the strongest plays.
    public func hold(_ source: String, hz: Double, level: Double, ttlMS: Double = 250) {
        lock.lock()
        if level <= 0 { holds[source] = nil }
        else { holds[source] = (min(400, max(40, hz)), min(1, level), Clock.now() + max(10, ttlMS) / 1000) }
        let needThread = holdThread == nil && !holds.isEmpty
        if needThread {
            let t = Thread { [weak self] in self?.holdLoop() }
            t.qualityOfService = .userInteractive
            holdThread = t
            t.start()
        }
        lock.unlock()
    }

    public func release(_ source: String) { lock.lock(); holds[source] = nil; lock.unlock() }

    /// Stops every hold. (Patterns already playing finish; they're short.)
    public func stopAll() { lock.lock(); holds.removeAll(); lock.unlock() }

    private func holdLoop() {
        while true {
            let t = Clock.now()
            lock.lock()
            holds = holds.filter { $0.value.until > t }
            let strongest = holds.values.max { $0.level < $1.level }
            if strongest == nil { holdThread = nil }
            let g = _gain
            lock.unlock()
            guard let h = strongest else { return }
            var ms = 20.0
            if fingerAllows() {
                ms = Pulse(hz: h.hz, ms: 20, level: 1).wholeCycleMS
                Trackpad.shared.playTone(hz: h.hz, ms: ms, level: h.level * g)
            }
            Clock.wait(until: t + ms / 1000)
        }
    }

    // MARK: Commands from the bridge

    public func perform(_ c: TactusCommand) {
        switch c {
        case .play(let name, let level): play(name, level: level)
        case .pattern(let p, let level): play(p, level: level)
        case .pulse(let p): play(p)
        case .hold(let source, let hz, let level, let ttl): hold(source, hz: hz, level: level, ttlMS: ttl)
        case .release(let source): release(source)
        case .stop: stopAll()
        }
    }
}
