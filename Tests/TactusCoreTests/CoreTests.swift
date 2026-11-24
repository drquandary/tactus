import XCTest
@testable import TactusCore

final class PatternTests: XCTestCase {
    func testLibraryNamesResolve() {
        for name in Pattern.names {
            let p = Pattern.named(name)
            XCTAssertNotNil(p, name)
            XCTAssertFalse(p!.pulses.isEmpty, name)
            for pulse in p!.pulses {
                XCTAssert((0...1).contains(pulse.level), name)
                XCTAssert(pulse.hz >= 40 && pulse.hz <= 4000, name)
            }
        }
        XCTAssertNotNil(Pattern.named("BUMP"), "names are case-insensitive")
    }

    func testParseSpec() {
        let p = Pattern.parse("230:9:0.5/55, 150:20:1")
        XCTAssertEqual(p?.pulses.count, 2)
        XCTAssertEqual(p?.pulses[0].gapMS, 55)
        XCTAssertEqual(p?.pulses[1].hz, 150)
        XCTAssertNil(Pattern.parse("230:9"))
        XCTAssertNil(Pattern.parse("a:b:c"))
        XCTAssertNil(Pattern.parse(""))
    }

    func testClampingAndWholeCycles() {
        let p = Pulse(hz: 10, ms: -5, level: 3)
        XCTAssertEqual(p.hz, 40); XCTAssertEqual(p.ms, 1); XCTAssertEqual(p.level, 1)
        for hz in [60.0, 100, 143, 250, 400] {
            let ms = Pulse(hz: hz, ms: 10, level: 1).wholeCycleMS
            let cycles = ms / 1000 * hz
            XCTAssertEqual(cycles, cycles.rounded(), accuracy: 1e-9)
            XCTAssertGreaterThanOrEqual(cycles, 1)
        }
    }
}

final class CommandTests: XCTestCase {
    func one(_ s: String) -> TactusCommand? {
        let c = CommandParser.parse(s.data(using: .utf8)!)
        return c.count == 1 ? c[0] : nil
    }

    func testText() {
        XCTAssertEqual(one("play bump 0.8"), .play(name: "bump", level: 0.8))
        XCTAssertEqual(one("bump"), .play(name: "bump", level: 1))
        XCTAssertEqual(one("  Heartbeat 0.5 \n"), .play(name: "heartbeat", level: 0.5))
        XCTAssertEqual(one("pulse 150 20 0.9"), .pulse(Pulse(hz: 150, ms: 20, level: 0.9)))
        XCTAssertEqual(one("hold engine 60 0.5 300"), .hold(source: "engine", hz: 60, level: 0.5, ttlMS: 300))
        XCTAssertEqual(one("hold engine 60 7"), .hold(source: "engine", hz: 60, level: 1, ttlMS: 250))
        XCTAssertEqual(one("release engine"), .release(source: "engine"))
        XCTAssertEqual(one("stop"), .stop)
        XCTAssertEqual(one("play bump 0.8;\n"), .play(name: "bump", level: 0.8), "Pure Data's FUDI semicolon")
        if case .pattern(let p, let level)? = one("pattern 230:9:0.5/55,230:9:0.5 0.7") {
            XCTAssertEqual(p.pulses.count, 2); XCTAssertEqual(level, 0.7)
        } else { XCTFail("pattern") }
        XCTAssertNil(one("play nosuchpattern"))
        XCTAssertNil(one("pulse"))
        XCTAssertNil(one("hello"))
        XCTAssertEqual(CommandParser.parse("tick\nbump".data(using: .utf8)!).count, 2, "one command per line")
    }

    func testJSON() {
        XCTAssertEqual(one(#"{"play":"bump","level":0.8}"#), .play(name: "bump", level: 0.8))
        XCTAssertEqual(one(#"{"pulse":[150,20,0.9]}"#), .pulse(Pulse(hz: 150, ms: 20, level: 0.9)))
        XCTAssertEqual(one(#"{"hold":"rain","hz":90,"level":0.3,"ttl":500}"#), .hold(source: "rain", hz: 90, level: 0.3, ttlMS: 500))
        XCTAssertEqual(one(#"{"release":"rain"}"#), .release(source: "rain"))
        XCTAssertEqual(one(#"{"stop":true}"#), .stop)
        XCTAssertNil(one(#"{"play":"nope"}"#))
        XCTAssertNil(one("{not json"))
    }

    func testOSCRoundTrip() {
        let msg = OSC.encode(address: "/tactus/play", args: [.string("bump"), .float(0.5)])
        XCTAssertEqual(msg.count % 4, 0)
        XCTAssertEqual(CommandParser.parse(msg), [.play(name: "bump", level: 0.5)])
        let pulse = OSC.encode(address: "/tactus/pulse", args: [.int(150), .float(20), .double(0.9)])
        XCTAssertEqual(CommandParser.parse(pulse), [.pulse(Pulse(hz: 150, ms: 20, level: 0.9))])
        let hold = OSC.encode(address: "/tactus/hold", args: [.string("engine"), .float(60), .float(0.4)])
        XCTAssertEqual(CommandParser.parse(hold), [.hold(source: "engine", hz: 60, level: Double(Float(0.4)), ttlMS: 250)])
        XCTAssertEqual(CommandParser.parse(OSC.encode(address: "/tactus/stop", args: [])), [.stop])
        XCTAssertEqual(CommandParser.parse(OSC.encode(address: "/other/play", args: [.string("bump")])), [])
    }

    func testOSCBundleAndGarbage() {
        let a = OSC.encode(address: "/tactus/play", args: [.string("tick")])
        let b = OSC.encode(address: "/tactus/play", args: [.string("bump")])
        var bundle = Data("#bundle".utf8); bundle.append(0)
        bundle.append(Data(repeating: 0, count: 8))
        for m in [a, b] {
            let n = UInt32(m.count)
            bundle.append(contentsOf: [UInt8(n >> 24), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)])
            bundle.append(m)
        }
        XCTAssertEqual(CommandParser.parse(bundle), [.play(name: "tick", level: 1), .play(name: "bump", level: 1)])
        // Truncated and random input must not crash.
        XCTAssertEqual(CommandParser.parse(a.prefix(a.count - 6)), [], "cut inside the string argument")
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<500 {
            var junk = Data((0..<Int.random(in: 1...64, using: &rng)).map { _ in UInt8.random(in: 0...255, using: &rng) })
            junk[0] = UInt8(ascii: "/")
            _ = CommandParser.parse(junk)
        }
    }
}

final class MIDITests: XCTestCase {
    func testParserRunningStatusAndRealtime() {
        var p = MIDIParser()
        // Note on, then running-status note on with a clock byte in the middle, then velocity-0 note off.
        let ev = p.feed([0x90, 36, 100, 38, 0xF8, 90, 36, 0])
        XCTAssertEqual(ev, [.noteOn(channel: 0, note: 36, velocity: 100), .clock,
                            .noteOn(channel: 0, note: 38, velocity: 90), .noteOff(channel: 0, note: 36)])
        XCTAssertEqual(p.feed([0xF0, 1, 2, 3, 0xF7, 0x89, 60, 0]), [.noteOff(channel: 9, note: 60)], "sysex skipped")
        XCTAssertEqual(p.feed([0xFA, 0xFC, 0xFB]), [.start, .stop, .continuePlayback])
        XCTAssertEqual(p.feed([0xF2, 0x10, 0x01]), [.songPosition(0x10 | 1 << 7)])
        XCTAssertEqual(p.feed([0xB2, 7, 127]), [.controlChange(channel: 2, controller: 7, value: 127)])
    }

    func testBeatCounter() {
        var c = BeatCounter(beatsPerBar: 4)
        _ = c.handle(.start)
        var ticks: [BeatTick] = []
        for _ in 0..<(24 * 8) { if let t = c.handle(.clock) { ticks.append(t) } }
        XCTAssertEqual(ticks, [.downbeat, .beat, .beat, .beat, .downbeat, .beat, .beat, .beat])
        _ = c.handle(.stop)
        XCTAssertNil(c.handle(.clock), "no beats while stopped")
        _ = c.handle(.songPosition(4))   // one beat in (4 sixteenths)
        _ = c.handle(.continuePlayback)
        XCTAssertEqual(c.handle(.clock), .beat)
    }

    func testDrumMapAndPitch() {
        XCTAssertEqual(DrumMap.patternName(note: 36), "kick")
        XCTAssertEqual(DrumMap.patternName(note: 38), "snare")
        XCTAssertEqual(DrumMap.patternName(note: 42), "hat")
        XCTAssertNil(DrumMap.patternName(note: 60))
        for n in UInt8(0)...UInt8(127) {
            let f = DrumMap.feelableHz(note: n)
            XCTAssert(f >= 60 && f <= 400, "\(n): \(f)")
        }
        XCTAssertEqual(DrumMap.feelableHz(note: 69 - 12), 220, accuracy: 0.01)
    }
}

final class BassTests: XCTestCase {
    func blocks(_ f: (Int) -> Float, seconds: Double, sr: Double = 48000, block: Int = 480) -> [[Float]] {
        let n = Int(seconds * sr)
        return stride(from: 0, to: n, by: block).map { s in (s..<min(n, s + block)).map(f) }
    }

    func testSilenceIsQuiet() {
        let d = BassDetector(sampleRate: 48000)
        for b in blocks({ _ in 0 }, seconds: 1) { XCTAssertEqual(d.process(b), BassReading(level: 0, onset: false)) }
    }

    func testKicksAreDetectedAndTrebleIsNot() {
        let sr = 48000.0
        // A 55 Hz "kick" for 80 ms every 0.5 s, over a constant quiet 3 kHz tone.
        let signal: (Int) -> Float = { i in
            let t = Double(i) / sr
            let kick = t.truncatingRemainder(dividingBy: 0.5) < 0.08 ? 0.8 * sin(2 * .pi * 55 * t) : 0
            return Float(kick + 0.3 * sin(2 * .pi * 3000 * t))
        }
        let d = BassDetector(sampleRate: sr)
        var onsets = 0
        for b in blocks(signal, seconds: 4) { if d.process(b).onset { onsets += 1 } }
        XCTAssert((6...9).contains(onsets), "expected about 8 kicks in 4 s, got \(onsets)")

        let treble = BassDetector(sampleRate: sr)
        var maxLevel = 0.0
        for (k, b) in blocks({ i in Float(0.8 * sin(2 * .pi * 3000 * Double(i) / sr)) }, seconds: 2).enumerated() {
            let level = treble.process(b).level
            if k >= 10 { maxLevel = max(maxLevel, level) }   // skip the filter's first 100 ms of settling
        }
        XCTAssertLessThan(maxLevel, 0.05, "a loud 3 kHz tone should barely register")
    }
}

final class RoleCueTests: XCTestCase {
    func testRoles() {
        XCTAssertEqual(RoleCue.patternName(role: "AXButton", subrole: "AXCloseButton", checked: nil), "close")
        XCTAssertEqual(RoleCue.patternName(role: "AXButton", subrole: nil, checked: nil), "button")
        XCTAssertEqual(RoleCue.patternName(role: "AXLink", subrole: nil, checked: nil), "link")
        XCTAssertEqual(RoleCue.patternName(role: "AXCheckBox", subrole: nil, checked: true), "toggle-on")
        XCTAssertEqual(RoleCue.patternName(role: "AXCheckBox", subrole: nil, checked: false), "toggle-off")
        XCTAssertEqual(RoleCue.patternName(role: "AXRadioButton", subrole: "AXTabButton", checked: true), "button")
        XCTAssertNil(RoleCue.patternName(role: "AXStaticText", subrole: nil, checked: nil))
        for role in ["AXButton", "AXLink", "AXTextField", "AXSlider", "AXMenuItem", "AXHeading", "AXImage", "AXPopUpButton"] {
            let name = RoleCue.patternName(role: role, subrole: nil, checked: nil)!
            XCTAssertNotNil(Pattern.named(name), "\(role) → \(name) must be a real pattern")
        }
    }
}

final class TextureTests: XCTestCase {
    func grating(_ period: Int, w: Int = 4000, h: Int = 20) -> LumaMap {
        var d = [Float](repeating: 1, count: w * h)
        for y in 0..<h { for x in 0..<w where (x % period) < period / 2 { d[y * w + x] = 0 } }
        return LumaMap(width: w, height: h, data: d)
    }

    /// Moves sideways at `speed` points/s, stepping like the app's loop.
    func run(_ map: LumaMap, speed: Double, seconds: Double, s: TextureSettings = TextureSettings()) -> [Haptic] {
        let e = TextureEngine()
        var x = 10.0, t = 0.0, out: [Haptic] = []
        var last = Point2(x: x, y: 10), dt = s.tickMS / 1000
        while t < seconds {
            t += dt; x += speed * dt
            let here = Point2(x: x, y: 10)
            let r = e.step(map: map, from: last, to: here, pixelsPerPoint: 1, dt: dt, settings: s)
            last = here
            var wait = s.tickMS
            if let h = r.haptic { out.append(h); wait = max(wait, h.ms) }
            dt = wait / 1000
        }
        return out
    }

    func testStripesBuzzAtSpeedOverPeriod() {
        let hs = run(grating(8), speed: 800, seconds: 2)
        let mean = hs.map(\.hz).reduce(0, +) / Double(hs.count)
        XCTAssertEqual(mean, 100, accuracy: 5)
        XCTAssert(hs.allSatisfy { $0.kind == .buzz })
    }

    func testWideStripesClick() {
        let hs = run(grating(32), speed: 800, seconds: 2)
        let clicks = hs.filter { $0.kind == .click }.count
        XCTAssertEqual(Double(clicks) / 2, 50, accuracy: 10)   // two edges per stripe period
    }

    func testStillAndBlankAreSilent() {
        XCTAssert(run(grating(8), speed: 0, seconds: 1).isEmpty)
        let white = LumaMap(width: 4000, height: 20, data: .init(repeating: 1, count: 80000))
        XCTAssert(run(white, speed: 800, seconds: 1).isEmpty)
    }
}
