// Tactus · SignalsModule.swift
//
// Surface Mouse-style haptic signals, in every app:
//   Window snapping   a bump when a window lands on full screen, a half or a quarter; ticks while resizing
//   Scroll ticks      a light tick every few lines, like the notches of a scroll wheel
//   Drag and drop     a bump when you pick something up and another when you drop it
//   Button hover      a tick on buttons, a double tick on a window's Close button

import AppKit
import ApplicationServices
import TactusCore

public final class SignalsModule: TactusModule {
    public let id = "signals"
    public let title = "Signals"
    public let summary = "Window snaps, scroll ticks, drag and drop, button hover"
    public var permissions: [TactusPermission] { [.accessibility] }
    public private(set) var isRunning = false

    enum Feature: String, CaseIterable { case windows = "Window snapping", scroll = "Scroll ticks", drag = "Drag and drop", hover = "Button hover" }
    private let flags = Flags(Set(Feature.allCases))

    private var scrollMonitor: Any?
    private var scrollAccum = 0.0
    private let pointsPerTick = 50.0
    private var dragTimer: Timer?
    private var buttonWasDown = false, dragBaseline = 0, picked = false
    private var windowObserver: AX.FrontmostObserver?
    private var windows: [CFHashCode: (snap: String?, tickSize: CGSize)] = [:]
    private var hover: HoverWatcher?

    public init() {}

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        scrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] e in self?.scrolled(e) }
        dragTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.pollDrag() }
        windowObserver = AX.FrontmostObserver(notifications: [kAXWindowMovedNotification, kAXWindowResizedNotification]) { [weak self] el, note in
            self?.windowChanged(el, resized: note == kAXWindowResizedNotification)
        }
        windowObserver?.start()
        hover = HoverWatcher { [weak self] el in
            guard let self, self.flags.contains(.hover) else { return nil }
            guard let cue = AX.cue(for: el), cue.pattern == "button" || cue.pattern == "close" || cue.pattern == "link" else { return nil }
            return cue
        } onEnter: { cue in
            Haptics.shared.play(cue.pattern == "close" ? "close" : "tick", light: cue.pattern != "close")
        }
        hover?.start()
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        scrollMonitor = nil
        dragTimer?.invalidate(); dragTimer = nil
        windowObserver?.stop(); windowObserver = nil
        hover?.stop(); hover = nil
        windows.removeAll()
    }

    public func menuItems() -> [NSMenuItem] {
        Feature.allCases.map { f in
            ClosureMenuItem(f.rawValue, checked: flags.contains(f)) { [weak self] in self?.flags.toggle(f) }
        }
    }

    // MARK: Scroll ticks

    private func scrolled(_ e: NSEvent) {
        guard flags.contains(.scroll), e.momentumPhase.isEmpty else { return }   // no ticks on the glide after a flick
        if e.phase.contains(.began) { scrollAccum = 0 }
        let scale = e.hasPreciseScrollingDeltas ? 1.0 : 10.0
        scrollAccum += Double(hypot(e.scrollingDeltaX, e.scrollingDeltaY)) * scale
        if scrollAccum >= pointsPerTick {
            scrollAccum = scrollAccum.truncatingRemainder(dividingBy: pointsPerTick)
            Haptics.shared.play("tick", level: 0.8, light: true)
        }
    }

    // MARK: Drag and drop

    /// A real drag-and-drop (a file, text or an image, not a window or a selection) writes to the system's
    /// drag pasteboard, so its change count tells us when something was picked up.
    private func pollDrag() {
        guard flags.contains(.drag) else { buttonWasDown = false; picked = false; return }
        let down = NSEvent.pressedMouseButtons & 1 != 0
        let count = NSPasteboard(name: .drag).changeCount
        if down && !buttonWasDown { dragBaseline = count; picked = false }
        else if down && !picked && count != dragBaseline { picked = true; Haptics.shared.play("bump") }
        else if !down && buttonWasDown && picked { picked = false; Haptics.shared.play("bump", grace: 0.5) }
        buttonWasDown = down
    }

    // MARK: Window snapping

    private func windowChanged(_ el: AXUIElement, resized: Bool) {
        guard flags.contains(.windows), let f = AX.frame(el) else { return }
        let key = CFHash(el)
        let snap = Self.snapName(f)
        var st = windows[key] ?? (snap: nil, tickSize: f.size)
        if let snap, snap != st.snap { Haptics.shared.play("snap", grace: 0.8) }   // a snap lands as you let go
        st.snap = snap
        if resized && (abs(f.width - st.tickSize.width) >= 40 || abs(f.height - st.tickSize.height) >= 40) {
            Haptics.shared.play("tick", light: true)
            st.tickSize = f.size
        }
        windows[key] = st
    }

    /// The snap position a frame matches (full screen, a half or a quarter), if any. The tolerance covers
    /// macOS's optional margins around tiled windows.
    static func snapName(_ f: CGRect) -> String? {
        let tol: CGFloat = 20
        for screen in NSScreen.screens {
            let r = AX.visibleFrame(screen)
            guard r.insetBy(dx: -tol, dy: -tol).contains(CGPoint(x: f.midX, y: f.midY)) else { continue }
            let w = r.width / 2, h = r.height / 2
            let targets: [(String, CGRect)] = [
                ("full", r),
                ("left", CGRect(x: r.minX, y: r.minY, width: w, height: r.height)),
                ("right", CGRect(x: r.minX + w, y: r.minY, width: w, height: r.height)),
                ("top", CGRect(x: r.minX, y: r.minY, width: r.width, height: h)),
                ("bottom", CGRect(x: r.minX, y: r.minY + h, width: r.width, height: h)),
                ("top left", CGRect(x: r.minX, y: r.minY, width: w, height: h)),
                ("top right", CGRect(x: r.minX + w, y: r.minY, width: w, height: h)),
                ("bottom left", CGRect(x: r.minX, y: r.minY + h, width: w, height: h)),
                ("bottom right", CGRect(x: r.minX + w, y: r.minY + h, width: w, height: h)),
            ]
            for (name, t) in targets where abs(f.minX - t.minX) <= tol && abs(f.maxX - t.maxX) <= tol
                && abs(f.minY - t.minY) <= tol && abs(f.maxY - t.maxY) <= tol {
                return name
            }
        }
        return nil
    }
}

// MARK: - Shared helpers for modules

/// A small thread-safe set of options.
final class Flags<T: Hashable>: @unchecked Sendable {
    private let lock = NSLock()
    private var on: Set<T>
    init(_ initial: Set<T>) { on = initial }
    func contains(_ x: T) -> Bool { lock.lock(); defer { lock.unlock() }; return on.contains(x) }
    func toggle(_ x: T) { lock.lock(); defer { lock.unlock() }; if on.contains(x) { on.remove(x) } else { on.insert(x) } }
    func set(_ x: T, _ value: Bool) { lock.lock(); defer { lock.unlock() }; if value { on.insert(x) } else { on.remove(x) } }
}

/// Watches what's under the pointer (about 30 times a second, on its own queue so a slow app can't stall the
/// menu bar) and reports when it moves onto a new element of interest.
final class HoverWatcher {
    typealias Match = (element: AXUIElement, pattern: String)
    private let queue = DispatchQueue(label: "tactus.hover", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private let systemWide = AXUIElementCreateSystemWide()
    private var lastPointer = CGPoint(x: -1, y: -1)
    private var last: AXUIElement?
    private let match: (AXUIElement) -> Match?
    private let onEnter: (Match) -> Void

    init(match: @escaping (AXUIElement) -> Match?, onEnter: @escaping (Match) -> Void) {
        self.match = match
        self.onEnter = onEnter
        AXUIElementSetMessagingTimeout(systemWide, 0.1)
    }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(33))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    func stop() { timer?.cancel(); timer = nil }

    private var count = 0
    private var trusted = false

    private func tick() {
        if count % 60 == 0 { trusted = AXIsProcessTrusted() }   // checking every tick is wasteful; every 2 s is plenty
        count += 1
        guard trusted, let p = AX.pointer() else { return }
        if abs(p.x - lastPointer.x) < 1 && abs(p.y - lastPointer.y) < 1 { return }
        lastPointer = p
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(p.x), Float(p.y), &hit) == .success, let hit,
              let m = match(hit) else { last = nil; return }
        if let last, CFEqual(last, m.element) { return }
        last = m.element
        onEnter(m)
    }
}
