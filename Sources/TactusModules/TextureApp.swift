// Tactus · TextureApp.swift
//
// The texture window (`tactus texture [image]`): an image you feel by moving the pointer over it with a
// finger on the trackpad. Edges mode turns light/dark ridges into clicks and buzz; Darkness mode makes dark
// areas rough.

import AppKit
import ImageIO
import UniformTypeIdentifiers
import TactusCore

final class TextureState: @unchecked Sendable {
    private let lock = NSLock()
    // Written by the main thread.
    private var _settings = TextureSettings()
    private var _luma: LumaMap?
    private var _rectCG = CGRect.zero        // the image on screen, global display coordinates (top-left origin)
    private var _active = false              // our window is key
    private var _paused = false
    private var _needFinger = true
    // Written by the haptic thread.
    private var _report = TickReport()
    private var _actuations = 0

    func with<T>(_ body: (TextureState) -> T) -> T { lock.lock(); defer { lock.unlock() }; return body(self) }

    var settings: TextureSettings { get { with { $0._settings } } set { with { $0._settings = newValue } } }
    var luma: LumaMap? { get { with { $0._luma } } set { with { $0._luma = newValue } } }
    var rectCG: CGRect { get { with { $0._rectCG } } set { with { $0._rectCG = newValue } } }
    var active: Bool { get { with { $0._active } } set { with { $0._active = newValue } } }
    var paused: Bool { get { with { $0._paused } } set { with { $0._paused = newValue } } }
    var needFinger: Bool { get { with { $0._needFinger } } set { with { $0._needFinger = newValue } } }
    var report: TickReport { get { with { $0._report } } set { with { $0._report = newValue } } }
    var actuations: Int { get { with { $0._actuations } } set { with { $0._actuations = newValue } } }
}
let textureState = TextureState()

// MARK: - The haptic loop (its own thread)

func textureHapticLoop() {
    let engine = TextureEngine()
    var last: Point2?
    var lastT = Clock.now()
    var countStart = Clock.now(), count = 0
    while true {
        let start = Clock.now()
        let s = textureState.settings
        var wait = s.tickMS
        let luma = textureState.luma
        let rect = textureState.rectCG
        let pad = Trackpad.shared
        let fingerOK = !textureState.needFinger || !pad.touchWorking || pad.fingerDown
        let t = Clock.now()
        if let luma, let p = CGEvent(source: nil)?.location, rect.width > 0, rect.contains(p),
           textureState.active, !textureState.paused, fingerOK {
            let here = Point2(x: Double(p.x - rect.minX) / Double(rect.width) * Double(luma.width),
                              y: Double(p.y - rect.minY) / Double(rect.height) * Double(luma.height))
            if let a = last {
                let r = engine.step(map: luma, from: a, to: here, pixelsPerPoint: Double(luma.width) / Double(rect.width),
                                    dt: t - lastT, settings: s)
                if let h = r.haptic {
                    Trackpad.shared.playTone(hz: h.hz, ms: h.ms, level: h.level)
                    count += 1
                    wait = max(wait, h.ms)
                }
                textureState.report = r
            }
            last = here
        } else {
            if last != nil { engine.reset(); textureState.report = TickReport() }
            last = nil
        }
        lastT = t
        if t - countStart >= 1 { textureState.actuations = count; count = 0; countStart = t }
        Clock.wait(until: start + wait / 1000)
    }
}

// MARK: - Images

/// The grayscale copy used for feeling, at most `maxSide` pixels on its long side.
public func makeLuma(_ image: CGImage, maxSide: Int = 1600) -> LumaMap? {
    let scale = min(1, Double(maxSide) / Double(max(image.width, image.height)))
    let w = max(1, Int(Double(image.width) * scale)), h = max(1, Int(Double(image.height) * scale))
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
    ctx.setFillColor(gray: 1, alpha: 1)            // transparent areas read as white (smooth)
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    guard let base = ctx.data else { return nil }
    let bpr = ctx.bytesPerRow
    let bytes = base.bindMemory(to: UInt8.self, capacity: bpr * h)
    var data = [Float](repeating: 1, count: w * h)
    for y in 0..<h { for x in 0..<w { data[y * w + x] = Float(bytes[y * bpr + x]) / 255 } }
    return LumaMap(width: w, height: h, data: data)
}

/// A test pattern. Top: stripes 4, 8, 16 and 32 px apart (move sideways across them; finer stripes should
/// feel higher). Bottom: a dark-to-light ramp, fine noise, and a coarse checkerboard.
func testPattern() -> CGImage? {
    let w = 1600, h = 1000
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
    ctx.setFillColor(gray: 1, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.setFillColor(gray: 0, alpha: 1)
    let band = 60   // white label band at the top of each panel (CG's y runs upward)
    // Top half: four stripe panels.
    let periods = [4, 8, 16, 32]
    let pw = w / periods.count
    for (i, p) in periods.enumerated() {
        var x = i * pw
        while x < (i + 1) * pw - p / 2 {
            ctx.fill(CGRect(x: x, y: h / 2, width: p / 2, height: h / 2 - band))
            x += p
        }
    }
    // Bottom half: ramp, noise, checkerboard.
    let third = w / 3, bh = h / 2 - band
    for x in 0..<third {
        ctx.setFillColor(gray: CGFloat(x) / CGFloat(third - 1), alpha: 1)
        ctx.fill(CGRect(x: x, y: 0, width: 1, height: bh))
    }
    var rng = SystemRandomNumberGenerator()
    for y in stride(from: 0, to: bh, by: 2) {
        for x in stride(from: third, to: 2 * third, by: 2) {
            ctx.setFillColor(gray: CGFloat(Double.random(in: 0...1, using: &rng)), alpha: 1)
            ctx.fill(CGRect(x: x, y: y, width: 2, height: 2))
        }
    }
    ctx.setFillColor(gray: 0, alpha: 1)
    let sq = 40
    for y in stride(from: 0, to: bh, by: sq) {
        for x in stride(from: 2 * third, to: w, by: sq) where ((x - 2 * third) / sq + y / sq) % 2 == 0 {
            ctx.fill(CGRect(x: x, y: y, width: min(sq, w - x), height: min(sq, bh - y)))
        }
    }
    // Labels, in the white bands.
    let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ns
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 28), .foregroundColor: NSColor.gray]
    for (i, p) in periods.enumerated() {
        ("stripes \(p) px" as NSString).draw(at: NSPoint(x: i * pw + 16, y: h - band + 14), withAttributes: attrs)
    }
    for (i, name) in ["ramp", "noise", "checkerboard"].enumerated() {
        (name as NSString).draw(at: NSPoint(x: i * third + 16, y: h / 2 - band + 14), withAttributes: attrs)
    }
    NSGraphicsContext.restoreGraphicsState()
    return ctx.makeImage()
}

// MARK: - The window

final class CanvasView: NSView {
    var image: NSImage?
    var name = "test pattern"
    let hudHeight: CGFloat = 78

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    func load(_ cg: CGImage, name: String) {
        guard let luma = makeLuma(cg) else { return }
        image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        self.name = name
        textureState.luma = luma
        needsDisplay = true
    }

    func load(url: URL) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { NSSound.beep(); return }
        load(cg, name: url.lastPathComponent)
    }

    /// Where the image sits in the view: as large as fits above the readout, keeping its proportions.
    var imageRect: NSRect {
        guard let image, image.size.width > 0, image.size.height > 0 else { return .zero }
        let area = NSRect(x: 16, y: hudHeight, width: bounds.width - 32, height: bounds.height - hudHeight - 16)
        guard area.width > 0, area.height > 0 else { return .zero }
        let s = min(area.width / image.size.width, area.height / image.size.height)
        let w = image.size.width * s, h = image.size.height * s
        return NSRect(x: area.midX - w / 2, y: area.midY - h / 2, width: w, height: h)
    }

    /// Tells the haptic thread where the image is on screen (global display coordinates, top-left origin).
    func syncGeometry() {
        guard let window, let primary = NSScreen.screens.first else { textureState.rectCG = .zero; return }
        let onScreen = window.convertToScreen(convert(imageRect, to: nil))
        textureState.rectCG = CGRect(x: onScreen.minX, y: primary.frame.maxY - onScreen.maxY,
                               width: onScreen.width, height: onScreen.height)
        textureState.active = window.isKeyWindow
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.96, alpha: 1).setFill()
        bounds.fill()
        image?.draw(in: imageRect)

        let s = textureState.settings, r = textureState.report
        let modeText = s.mode == .edges ? "1 Edges: contrast is texture" : "2 Darkness: dark is rough"
        let motorText = Trackpad.shared.isReady ? "motor ok" : "motor: \(Trackpad.shared.problem)"
        let touchText: String
        if !textureState.needFinger { touchText = "finger check off" }
        else if !Trackpad.shared.touchWorking { touchText = "finger check: no data yet (touch the trackpad)" }
        else { touchText = Trackpad.shared.fingerDown ? "finger down" : "finger up (no vibration)" }
        let nowText: String
        if let h = r.haptic {
            nowText = "\(h.kind.rawValue) \(String(format: "%.0f", h.hz)) Hz, strength \(String(format: "%.2f", h.level))"
        } else { nowText = "quiet" }
        let lines = [
            "\(name)   ·   \(modeText)   ·   strength \(String(format: "%.2f", s.gain))   ·   edge step \(String(format: "%.2f", s.edgeStep))   ·   \(motorText)   ·   \(touchText)\(textureState.paused ? "   ·   PAUSED" : "")",
            "now: \(nowText)   ·   " + String(format: "speed %.0f pt/s   ·   ridges %.0f per s   ·   darkness %.2f   ·   ",
                   r.speed, r.ridgeHz, r.darkness) + "\(textureState.actuations) actuations in the last second",
            "keys: 1 Edges, 2 Darkness, + / - strength, [ / ] edge step, t finger check, space pause, ⌘O open an image (or drag one in)",
        ]
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                                                    .foregroundColor: NSColor(white: 0.15, alpha: 1)]
        for (i, line) in lines.enumerated() {
            (line as NSString).draw(at: NSPoint(x: 16, y: CGFloat(52 - 18 * i)), withAttributes: attrs)
        }
    }

    override func keyDown(with event: NSEvent) {
        var s = textureState.settings
        switch event.charactersIgnoringModifiers ?? "" {
        case "1": s.mode = .edges
        case "2": s.mode = .darkness
        case "+", "=": s.gain = min(1, s.gain + 0.1)
        case "-", "_": s.gain = max(0.1, s.gain - 0.1)
        case "[": s.edgeStep = max(0.02, s.edgeStep - 0.02)
        case "]": s.edgeStep = min(0.6, s.edgeStep + 0.02)
        case "t": textureState.needFinger.toggle()
        case " ": textureState.paused.toggle()
        default: super.keyDown(with: event); return
        }
        textureState.settings = s
        needsDisplay = true
    }

    // Drag an image file onto the window.
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self])?.first as? URL else { return false }
        load(url: url)
        return true
    }
}

final class TextureAppDelegate: NSObject, NSApplicationDelegate {
    var imagePath: String?
    let window: NSWindow
    let canvas = CanvasView()
    var timer: Timer?

    override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 780),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        window.title = "Tactus · texture"
        window.contentView = canvas
        canvas.registerForDraggedTypes([.fileURL])
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        if let imagePath {
            canvas.load(url: URL(fileURLWithPath: imagePath))
        }
        if textureState.luma == nil, let cg = testPattern() { canvas.load(cg, name: "test pattern") }
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(canvas)
        NSApp.activate(ignoringOtherApps: true)
        // Keep the image's screen position and the readout current (15 times a second).
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.canvas.syncGeometry()
            self.canvas.needsDisplay = true
        }
        let thread = Thread { textureHapticLoop() }
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    @objc func openImage(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.beginSheetModal(for: window) { [weak self] response in
            if response == .OK, let url = panel.url { self?.canvas.load(url: url) }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ note: Notification) { Trackpad.shared.close() }
}


/// Runs the texture window until it's closed.
public enum TextureApp {
    public static func run(imagePath: String?, tickMS: Double) {
        var settings = textureState.settings
        settings.tickMS = tickMS
        textureState.settings = settings
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = TextureAppDelegate()
        delegate.imagePath = imagePath
        app.delegate = delegate
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Tactus", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let fileItem = NSMenuItem()
        mainMenu.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        let openItem = NSMenuItem(title: "Open Image…", action: #selector(TextureAppDelegate.openImage(_:)), keyEquivalent: "o")
        openItem.target = delegate
        fileMenu.addItem(openItem)
        fileItem.submenu = fileMenu
        app.mainMenu = mainMenu
        app.run()
    }
}
