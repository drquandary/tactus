// Tactus · Trackpad.swift
//
// The trackpad's haptic motor and finger detection, through MultitouchSupport, a private macOS framework,
// using the same calls as nospeaker (github.com/os6/nospeaker, MIT licence, © 2026 Cody Collier; see
// NOTICE). It is undocumented and may change with any macOS update. The motor is never driven past its
// normal maximum strength.

import AppKit
import Darwin

// MARK: - Clock

public enum Clock {
    public static let ticksPerSecond: Double = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return 1e9 * Double(tb.denom) / Double(tb.numer)
    }()
    static let start = mach_absolute_time()

    /// Seconds since the clock started. (`start` is read before the time: statics start up on first use,
    /// and reading the time first would make the subtraction negative.)
    public static func now() -> Double {
        let s = start
        let t = mach_absolute_time()
        return t > s ? Double(t - s) / ticksPerSecond : 0
    }

    /// Sleeps until `now()` reaches `t`, spinning only for the last ~1.5 ms to keep timing tight.
    public static func wait(until t: Double) {
        while true {
            let left = t - now()
            if left <= 0 { return }
            if left > 0.0015 { usleep(useconds_t((left - 0.0015) * 1e6)) }
        }
    }
}

// MARK: - MultitouchSupport, resolved at run time

private let mt = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW)
private func sym<T>(_ name: String, _: T.Type) -> T? {
    guard let mt, let p = dlsym(mt, name) else { return nil }
    return unsafeBitCast(p, to: T.self)
}

private typealias CreateList = @convention(c) () -> Unmanaged<CFArray>?
private typealias GetID = @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<UInt64>) -> Int32
private typealias IsBuiltIn = @convention(c) (UnsafeMutableRawPointer) -> Bool
private typealias ActuatorCreate = @convention(c) (UInt64) -> Unmanaged<CFTypeRef>?
private typealias ActuatorOpen = @convention(c) (CFTypeRef) -> Int32
private typealias ActuatorClose = @convention(c) (CFTypeRef) -> Int32
private typealias ActuationCreate = @convention(c) (CFDictionary, Int32) -> UnsafeMutableRawPointer?
private typealias ActuationPlay = @convention(c) (UnsafeMutableRawPointer, UnsafeMutableRawPointer, UInt32, Float, Float) -> Int32
private typealias FrameCallback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32
private typealias RegisterCallback = @convention(c) (UnsafeMutableRawPointer, FrameCallback) -> Void
private typealias DeviceStart = @convention(c) (UnsafeMutableRawPointer, Int32) -> Void
private typealias DeviceStop = @convention(c) (UnsafeMutableRawPointer) -> Void

private let createList = sym("MTDeviceCreateList", CreateList.self)
private let getID = sym("MTDeviceGetDeviceID", GetID.self)
private let isBuiltIn = sym("MTDeviceIsBuiltIn", IsBuiltIn.self)
private let actuatorCreate = sym("MTActuatorCreateFromDeviceID", ActuatorCreate.self)
private let actuatorOpen = sym("MTActuatorOpen", ActuatorOpen.self)
private let actuatorClose = sym("MTActuatorClose", ActuatorClose.self)
private let actuationCreate = sym("MTActuationCreateFromDictionary", ActuationCreate.self)
private let actuationPlay = sym("MTActuationActuate", ActuationPlay.self)
private let registerCallback = sym("MTRegisterContactFrameCallback", RegisterCallback.self)
private let unregisterCallback = sym("MTUnregisterContactFrameCallback", RegisterCallback.self)
private let deviceStart = sym("MTDeviceStart", DeviceStart.self)
private let deviceStop = sym("MTDeviceStop", DeviceStop.self)

/// Contact records are 96 bytes; the state at byte 20 is 3…5 while a finger touches (as read in nospeaker).
private let touchCallback: FrameCallback = { _, data, count, _, _ in
    var down = false
    if let data, count > 0 {
        for i in 0..<Int(count) where (3...5).contains(data.advanced(by: i * 96).load(fromByteOffset: 20, as: Int32.self)) {
            down = true
        }
    }
    Trackpad.shared.setFinger(down)
    return 0
}

// MARK: - Trackpad

public final class Trackpad: @unchecked Sendable {
    public static let shared = Trackpad()

    private let lock = NSLock()
    private var motor: CFTypeRef?
    private var motorPointer: UnsafeMutableRawPointer?
    private var deviceList: CFArray?
    private var deviceID: UInt64 = 0
    private var touchStarted = false
    private var _fingerDown = false
    private var _lastFinger = -1000.0
    private var _touchWorking = false

    /// Why the motor couldn't be opened, if it couldn't.
    public private(set) var problem = ""
    public var isReady: Bool { lock.lock(); defer { lock.unlock() }; return motorPointer != nil }

    private init() {}

    /// Opens the motor and starts finger detection. Prefers the built-in trackpad; with `external`, only a
    /// Magic Trackpad. Safe to call more than once.
    @discardableResult
    public func open(external: Bool = false) -> Bool {
        _ = Clock.now()   // start the clock before the touch callbacks begin
        if isReady { return true }
        guard let createList, let getID, let actuatorCreate, let actuatorOpen, actuationCreate != nil, actuationPlay != nil else {
            problem = "this macOS doesn't have the trackpad functions Tactus needs"; return false
        }
        guard let list = createList()?.takeRetainedValue(), CFArrayGetCount(list) > 0 else {
            problem = "no trackpad found"; return false
        }
        var ids: [(id: UInt64, builtIn: Bool)] = []
        for i in 0..<CFArrayGetCount(list) {
            guard let raw = CFArrayGetValueAtIndex(list, i) else { continue }
            var id: UInt64 = 0
            let dev = UnsafeMutableRawPointer(mutating: raw)
            if getID(dev, &id) == 0 { ids.append((id, isBuiltIn?(dev) ?? false)) }
        }
        let candidates = external ? ids.filter { !$0.builtIn } : ids.sorted { $0.builtIn && !$1.builtIn }
        for d in candidates {
            if let ref = actuatorCreate(d.id)?.takeRetainedValue(), actuatorOpen(ref) == 0 {
                lock.lock()
                motor = ref
                motorPointer = Unmanaged.passUnretained(ref as AnyObject).toOpaque()
                deviceList = list
                deviceID = d.id
                lock.unlock()
                startTouch()
                return true
            }
        }
        problem = external ? "no external Force Touch trackpad found" : "no Force Touch trackpad found"
        return false
    }

    public func close() {
        stopTouch()
        lock.lock(); defer { lock.unlock() }
        if let motor { _ = actuatorClose?(motor) }
        motor = nil; motorPointer = nil
    }

    /// Plays one sine tone. The length is rounded to whole cycles; `level` is 0…1.
    public func playTone(hz: Double, ms: Double, level: Double) {
        guard let actuationCreate, let actuationPlay, level > 0 else { return }
        lock.lock(); let ptr = motorPointer; lock.unlock()
        guard let ptr else { return }
        let len = Pulse(hz: hz, ms: ms, level: level).wholeCycleMS
        let shape: [String: Any] = [
            "BaseWaveform": ["Type": "Gaussian", "Amplitude": 0.0, "DurationMS": len],
            "Tones": [["Type": "Sine", "Amplitude": 1.0, "DurationMS": len, "DelayMS": 0.0, "FrequencykHz": hz / 1000]],
        ]
        guard let act = actuationCreate(shape as CFDictionary, 0) else { return }
        _ = actuationPlay(act, ptr, 0, Float(min(1, max(0, level))), 0)
        Unmanaged<AnyObject>.fromOpaque(act).release()
    }

    // MARK: Finger

    public var fingerDown: Bool { lock.lock(); defer { lock.unlock() }; return _fingerDown }
    /// When a finger was last on the trackpad, on `Clock.now()`.
    public var lastFingerTime: Double { lock.lock(); defer { lock.unlock() }; return _lastFinger }
    /// True once finger data has arrived at least once.
    public var touchWorking: Bool { lock.lock(); defer { lock.unlock() }; return _touchWorking }

    fileprivate func setFinger(_ down: Bool) {
        let t = Clock.now()
        lock.lock(); _fingerDown = down; _touchWorking = true; if down { _lastFinger = t }; lock.unlock()
    }

    private func devices() -> [UnsafeMutableRawPointer] {
        guard let deviceList, let getID else { return [] }
        return (0..<CFArrayGetCount(deviceList)).compactMap { i -> UnsafeMutableRawPointer? in
            guard let raw = CFArrayGetValueAtIndex(deviceList, i) else { return nil }
            let dev = UnsafeMutableRawPointer(mutating: raw)
            var id: UInt64 = 0
            return getID(dev, &id) == 0 && id == deviceID ? dev : nil
        }
    }
    private func startTouch() {
        guard !touchStarted, let registerCallback, let deviceStart else { return }
        for d in devices() { registerCallback(d, touchCallback); deviceStart(d, 0) }
        touchStarted = true
    }
    private func stopTouch() {
        guard touchStarted else { return }
        for d in devices() { unregisterCallback?(d, touchCallback); deviceStop?(d) }
        touchStarted = false
    }
}
