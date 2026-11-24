// Tactus · Command.swift
//
// The commands other programs send to Tactus (see docs/PROTOCOL.md). One command per UDP datagram, in any of
// three forms:
//
//   Text   play bump 0.8 · bump · pulse 150 20 0.9 · pattern 230:9:0.5/55,230:9:0.5 0.8
//          hold engine 60 0.5 250 · release engine · stop
//   JSON   {"play":"bump","level":0.8} · {"pulse":[150,20,0.9]} · {"pattern":"230:9:0.5/55,230:9:0.5"}
//          {"hold":"engine","hz":60,"level":0.5,"ttl":250} · {"release":"engine"} · {"stop":true}
//   OSC    /tactus/play ,s[f] · /tactus/pulse ,fff · /tactus/pattern ,s[f] · /tactus/hold ,sff[f]
//          /tactus/release ,s · /tactus/stop
//
// `hold` keeps a steady vibration going (an engine, rain, a drone) until it is released or its time-to-live
// runs out without being refreshed. Send it again before `ttl` ms pass to keep it going or to change it.

import Foundation

public enum TactusCommand: Equatable, Sendable {
    case play(name: String, level: Double)
    case pattern(Pattern, level: Double)
    case pulse(Pulse)
    case hold(source: String, hz: Double, level: Double, ttlMS: Double)
    case release(source: String)
    case stop
}

public enum CommandParser {
    /// Parses one datagram: OSC if it starts with "/" or "#bundle", JSON if it starts with "{", text otherwise.
    /// An OSC bundle can hold several commands.
    public static func parse(_ data: Data) -> [TactusCommand] {
        guard let first = data.first else { return [] }
        if first == UInt8(ascii: "/") || first == UInt8(ascii: "#") {
            return OSC.parse(data).compactMap { command(address: $0.address, args: $0.args) }
        }
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") { return parseJSON(trimmed).map { [$0] } ?? [] }
        return trimmed.split(whereSeparator: \.isNewline).compactMap { parseText(String($0)) }
    }

    public static func parseText(_ line: String) -> TactusCommand? {
        // Pure Data's [netsend] ends each message with ";" (FUDI); ignore it.
        let clean = line.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: ";"))
        let w = clean.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let verb = w.first?.lowercased() else { return nil }
        func num(_ i: Int) -> Double? { i < w.count ? Double(w[i]) : nil }
        switch verb {
        case "play":
            guard w.count >= 2, Pattern.named(w[1]) != nil else { return nil }
            return .play(name: w[1].lowercased(), level: num(2) ?? 1)
        case "pulse":
            guard let hz = num(1), let ms = num(2) else { return nil }
            return .pulse(Pulse(hz: hz, ms: ms, level: num(3) ?? 1))
        case "pattern":
            guard w.count >= 2, let p = Pattern.parse(w[1]) else { return nil }
            return .pattern(p, level: num(2) ?? 1)
        case "hold":
            guard w.count >= 4, let hz = num(2), let level = num(3) else { return nil }
            return .hold(source: w[1], hz: hz, level: clamp(level), ttlMS: num(4) ?? 250)
        case "release":
            guard w.count >= 2 else { return nil }
            return .release(source: w[1])
        case "stop":
            return .stop
        default:
            // A bare pattern name, optionally with a level: "bump" or "bump 0.5".
            guard Pattern.named(verb) != nil else { return nil }
            return .play(name: verb, level: num(1) ?? 1)
        }
    }

    public static func parseJSON(_ text: String) -> TactusCommand? {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func d(_ key: String) -> Double? { (obj[key] as? NSNumber)?.doubleValue }
        let level = d("level") ?? 1
        if let name = obj["play"] as? String, Pattern.named(name) != nil {
            return .play(name: name.lowercased(), level: level)
        }
        if let arr = obj["pulse"] as? [NSNumber], arr.count >= 2 {
            return .pulse(Pulse(hz: arr[0].doubleValue, ms: arr[1].doubleValue, level: arr.count > 2 ? arr[2].doubleValue : 1))
        }
        if let spec = obj["pattern"] as? String, let p = Pattern.parse(spec) { return .pattern(p, level: level) }
        if let src = obj["hold"] as? String, let hz = d("hz") {
            return .hold(source: src, hz: hz, level: clamp(level), ttlMS: d("ttl") ?? 250)
        }
        if let src = obj["release"] as? String { return .release(source: src) }
        if obj["stop"] != nil { return .stop }
        return nil
    }

    static func command(address: String, args: [OSCArg]) -> TactusCommand? {
        let parts = address.split(separator: "/").map(String.init)
        guard parts.count == 2, parts[0] == "tactus" else { return nil }
        func n(_ i: Int) -> Double? { i < args.count ? args[i].number : nil }
        func s(_ i: Int) -> String? { i < args.count ? args[i].string : nil }
        switch parts[1] {
        case "play":
            guard let name = s(0), Pattern.named(name) != nil else { return nil }
            return .play(name: name.lowercased(), level: n(1) ?? 1)
        case "pulse":
            guard let hz = n(0), let ms = n(1) else { return nil }
            return .pulse(Pulse(hz: hz, ms: ms, level: n(2) ?? 1))
        case "pattern":
            guard let spec = s(0), let p = Pattern.parse(spec) else { return nil }
            return .pattern(p, level: n(1) ?? 1)
        case "hold":
            guard let src = s(0), let hz = n(1), let level = n(2) else { return nil }
            return .hold(source: src, hz: hz, level: clamp(level), ttlMS: n(3) ?? 250)
        case "release":
            guard let src = s(0) else { return nil }
            return .release(source: src)
        case "stop":
            return .stop
        default:
            return nil
        }
    }

    private static func clamp(_ x: Double) -> Double { min(1, max(0, x)) }
}

// MARK: - OSC (Open Sound Control), just enough for Tactus

public enum OSCArg: Equatable, Sendable {
    case int(Int32)
    case float(Float)
    case double(Double)
    case string(String)

    public var number: Double? {
        switch self {
        case .int(let v): return Double(v)
        case .float(let v): return Double(v)
        case .double(let v): return v
        case .string(let s): return Double(s)
        }
    }
    public var string: String? { if case .string(let s) = self { return s } else { return nil } }
}

public enum OSC {
    /// Every message in a datagram (bundles are flattened). Malformed input yields nothing rather than a crash.
    public static func parse(_ data: Data) -> [(address: String, args: [OSCArg])] {
        let bytes = [UInt8](data)
        return parse(bytes[...], depth: 0)
    }

    private static func parse(_ b: ArraySlice<UInt8>, depth: Int) -> [(address: String, args: [OSCArg])] {
        var i = b.startIndex
        guard let head = readString(b, &i) else { return [] }
        if head == "#bundle" {
            guard depth < 8, i + 8 <= b.endIndex else { return [] }
            i += 8   // time tag (ignored: commands play as they arrive)
            var out: [(address: String, args: [OSCArg])] = []
            while i + 4 <= b.endIndex {
                let size = Int(readUInt32(b, i)); i += 4
                guard size > 0, size % 4 == 0, i + size <= b.endIndex else { break }
                out += parse(b[i..<(i + size)], depth: depth + 1)
                i += size
            }
            return out
        }
        guard head.hasPrefix("/") else { return [] }
        guard i < b.endIndex, let tags = readString(b, &i), tags.hasPrefix(",") else { return [(head, [])] }
        var args: [OSCArg] = []
        for t in tags.dropFirst() {
            switch t {
            case "i":
                guard i + 4 <= b.endIndex else { return [] }
                args.append(.int(Int32(bitPattern: readUInt32(b, i)))); i += 4
            case "f":
                guard i + 4 <= b.endIndex else { return [] }
                args.append(.float(Float(bitPattern: readUInt32(b, i)))); i += 4
            case "d":
                guard i + 8 <= b.endIndex else { return [] }
                let hi = UInt64(readUInt32(b, i)), lo = UInt64(readUInt32(b, i + 4))
                args.append(.double(Double(bitPattern: hi << 32 | lo))); i += 8
            case "s", "S":
                guard let s = readString(b, &i) else { return [] }
                args.append(.string(s))
            case "T", "F", "N", "I":
                continue   // no payload
            default:
                return []  // unknown type: can't find the next argument safely
            }
        }
        return [(head, args)]
    }

    /// A null-terminated string padded to a multiple of 4 bytes.
    private static func readString(_ b: ArraySlice<UInt8>, _ i: inout Int) -> String? {
        guard let end = b[i...].firstIndex(of: 0) else { return nil }
        let s = String(decoding: b[i..<end], as: UTF8.self)
        i = min(b.endIndex, i + ((end - i) / 4 + 1) * 4)
        return s
    }

    private static func readUInt32(_ b: ArraySlice<UInt8>, _ i: Int) -> UInt32 {
        UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3])
    }

    /// Encodes one message (used by `tactus send --osc` and the tests).
    public static func encode(address: String, args: [OSCArg]) -> Data {
        var out = [UInt8]()
        func pad(_ s: String) { out += Array(s.utf8); out.append(0); while out.count % 4 != 0 { out.append(0) } }
        func u32(_ v: UInt32) { out += [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
        pad(address)
        pad("," + args.map { a -> String in
            switch a { case .int: return "i"; case .float: return "f"; case .double: return "d"; case .string: return "s" }
        }.joined())
        for a in args {
            switch a {
            case .int(let v): u32(UInt32(bitPattern: v))
            case .float(let v): u32(v.bitPattern)
            case .double(let v): u32(UInt32(v.bitPattern >> 32)); u32(UInt32(v.bitPattern & 0xFFFF_FFFF))
            case .string(let s): pad(s)
            }
        }
        return Data(out)
    }
}
