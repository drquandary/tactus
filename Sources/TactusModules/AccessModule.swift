// Tactus · AccessModule.swift
//
// Touch cues for blind and low-vision users, meant to work alongside VoiceOver, Zoom or on their own:
//
//   Element cues    each kind of control under the pointer feels different: a tick for a button, a rising
//                   double tick for a link, a soft hum for a text field, a firm or soft click for a checkbox
//                   that's on or off, three ticks for a heading, a slow pulse for an image
//   Focus cues      the same cues when keyboard focus moves (Tab, VoiceOver navigation)
//   Edges           a soft bump when the pointer crosses the edge of the front window, and a firm one when it
//                   reaches the edge of the screen, so you can tell where you are without looking
//   Screen texture  feel whatever is on screen under the pointer: contrast becomes ridges and buzz, as in the
//                   texture window (needs Screen Recording permission)
//
// Cues play while a finger rests on the trackpad. A keyboard user can keep a finger or the side of a hand on
// the pad to feel focus cues, or turn off "Only when a finger is on the trackpad" in the menu.

import AppKit
import ApplicationServices
import ScreenCaptureKit
import TactusCore

public final class AccessModule: TactusModule {
    public let id = "access"
    public let title = "Access"
    public let summary = "Touch cues for blind and low-vision users: controls, focus, edges, screen texture"
    public var permissions: [TactusPermission] { [.accessibility, .screenRecording] }
    public private(set) var isRunning = false

    enum Feature: String, CaseIterable {
        case elements = "Element cues under the pointer"
        case focus = "Focus cues (keyboard and VoiceOver)"
        case edges = "Window and screen edges"
        case texture = "Screen texture under the pointer"
    }
    private let flags = Flags<Feature>([.elements, .focus, .edges])
    private var hover: HoverWatcher?
    private var focusObserver: AX.FrontmostObserver?
    private var edgeTimer: DispatchSourceTimer?
    private let edgeQueue = DispatchQueue(label: "tactus.access.edges")
    private var screenTexture: ScreenTexture?

    public init() {}

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        hover = HoverWatcher { [weak self] el in
            guard let self, self.flags.contains(.elements) else { return nil }
            return AX.cue(for: el)
        } onEnter: { cue in
            Haptics.shared.play(cue.pattern, light: cue.pattern == "button" || cue.pattern == "menu")
        }
        hover?.start()
        focusObserver = AX.FrontmostObserver(notifications: [kAXFocusedUIElementChangedNotification]) { [weak self] el, _ in
            guard let self, self.flags.contains(.focus), let cue = AX.cue(for: el, depth: 1) else { return }
            Haptics.shared.play(cue.pattern, grace: 1.0)
        }
        focusObserver?.start()
        startEdges()
        if flags.contains(.texture) { startTexture() }
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        hover?.stop(); hover = nil
        focusObserver?.stop(); focusObserver = nil
        edgeTimer?.cancel(); edgeTimer = nil
        screenTexture?.stop(); screenTexture = nil
    }

    public func menuItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = Feature.allCases.map { f in
            ClosureMenuItem(f.rawValue, checked: flags.contains(f)) { [weak self] in
                guard let self else { return }
                self.flags.toggle(f)
                if f == .texture && self.isRunning {
                    if self.flags.contains(.texture) { self.startTexture() } else { self.screenTexture?.stop(); self.screenTexture = nil }
                }
            }
        }
        if flags.contains(.texture), !TactusPermission.screenRecording.granted {
            items.append(ClosureMenuItem("Screen texture needs Screen Recording permission…") { TactusPermission.screenRecording.request() })
        }
        return items
    }

    // MARK: Edges

    private enum Place: Equatable { case inside, outside, screenEdge }
    private var place: Place?
    private var frontWindow: CGRect?
    private var edgeCount = 0

    private func startEdges() {
        let t = DispatchSource.makeTimerSource(queue: edgeQueue)
        t.schedule(deadline: .now(), repeating: .milliseconds(20))
        t.setEventHandler { [weak self] in self?.edgeTick() }
        t.resume()
        edgeTimer = t
    }

    private func edgeTick() {
        guard flags.contains(.edges), let p = AX.pointer() else { place = nil; return }
        if edgeCount % 25 == 0 { frontWindow = Self.frontWindowFrame() }   // refresh twice a second
        edgeCount += 1
        let onScreenEdge = NSScreen.screens.contains { s in
            let f = AX.fullFrame(s)
            guard f.insetBy(dx: -1, dy: -1).contains(p) else { return false }
            return p.x <= f.minX + 0.5 || p.x >= f.maxX - 1.5 || p.y <= f.minY + 0.5 || p.y >= f.maxY - 1.5
        }
        let now: Place = onScreenEdge ? .screenEdge : (frontWindow?.contains(p) == true ? .inside : .outside)
        defer { place = now }
        guard let before = place, before != now else { return }
        if now == .screenEdge { Haptics.shared.play("thud", level: 0.8) }
        else if before != .screenEdge { Haptics.shared.play("edge", level: 0.6) }
    }

    private static func frontWindowFrame() -> CGRect? {
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        guard let w = AX.attr(appEl, kAXFocusedWindowAttribute), CFGetTypeID(w) == AXUIElementGetTypeID() else { return nil }
        return AX.frame(w as! AXUIElement)
    }

    // MARK: Screen texture

    private func startTexture() {
        guard screenTexture == nil else { return }
        guard TactusPermission.screenRecording.granted else { TactusPermission.screenRecording.request(); return }
        let st = ScreenTexture()
        screenTexture = st
        st.start()
    }
}

/// Captures a small square of the screen around the pointer about 30 times a second and runs it through the
/// texture engine, so whatever is on screen can be felt.
final class ScreenTexture {
    private let engine = TextureEngine()
    private var settings: TextureSettings = { var s = TextureSettings(); s.tickMS = 30; return s }()
    private var running = false
    private var filter: SCContentFilter?
    private var display: SCDisplay?
    private var lastPointer: CGPoint?
    private var lastTime = 0.0
    private let side: CGFloat = 160   // points captured around the pointer

    func start() {
        running = true
        Task { await refreshContent(); capture() }
    }

    func stop() { running = false }

    private func refreshContent() async {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return }
        let me = content.applications.filter { $0.processID == getpid() }
        let p = AX.pointer() ?? .zero
        let d = content.displays.first { $0.frame.contains(p) } ?? content.displays.first
        guard let d else { return }
        display = d
        filter = SCContentFilter(display: d, excludingApplications: me, exceptingWindows: [])
    }

    private func capture() {
        guard running else { return }
        guard let filter, let display, let p = AX.pointer() else {
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { Task { await self.refreshContent(); self.capture() } }
            return
        }
        if !display.frame.contains(p) {   // pointer moved to another display
            Task { await refreshContent(); capture() }
            return
        }
        let local = CGRect(x: p.x - display.frame.minX - side / 2, y: p.y - display.frame.minY - side / 2, width: side, height: side)
        let config = SCStreamConfiguration()
        config.sourceRect = local
        config.width = Int(side)
        config.height = Int(side)
        config.showsCursor = false
        let started = Clock.now()
        SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) { [weak self] image, _ in
            guard let self else { return }
            if let image, let luma = makeLuma(image) { self.feel(luma, origin: CGPoint(x: p.x - self.side / 2, y: p.y - self.side / 2), pointer: p) }
            let wait = max(0, 0.033 - (Clock.now() - started))
            DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + wait) { self.capture() }
        }
    }

    private func feel(_ luma: LumaMap, origin: CGPoint, pointer p: CGPoint) {
        let t = Clock.now()
        defer { lastPointer = p; lastTime = t }
        guard let a = lastPointer, Haptics.shared.fingerAllows(grace: 0) else { engine.reset(); return }
        let scale = Double(luma.width) / Double(side)
        let from = Point2(x: Double(a.x - origin.x) * scale, y: Double(a.y - origin.y) * scale)
        let to = Point2(x: Double(p.x - origin.x) * scale, y: Double(p.y - origin.y) * scale)
        settings.gain = 1
        let r = engine.step(map: luma, from: from, to: to, pixelsPerPoint: scale, dt: max(0.001, t - lastTime), settings: settings)
        if let h = r.haptic {
            Haptics.shared.play(Pulse(hz: h.hz, ms: h.ms, level: h.level), grace: 0)
        }
    }
}
