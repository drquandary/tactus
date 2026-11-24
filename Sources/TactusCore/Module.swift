// Tactus · Module.swift
//
// A module is one feature that turns something happening on the Mac into touch: window snaps, MIDI beats,
// game audio, the element under the pointer. The menu bar host lists every module and lets you turn each on
// and off. See docs/WRITING_A_MODULE.md.

import AppKit
import ApplicationServices
import CoreGraphics

public protocol TactusModule: AnyObject {
    /// Short, lowercase, stable: used on the command line (`tactus run music`) and to remember settings.
    var id: String { get }
    /// Shown in the menu.
    var title: String { get }
    /// One line on what it does, shown in the menu and in `tactus modules`.
    var summary: String { get }
    /// Permissions it needs to work fully. The host shows which are missing.
    var permissions: [TactusPermission] { get }
    var isRunning: Bool { get }
    /// Called on the main thread.
    func start()
    func stop()
    /// Extra menu items for the module's submenu (options, tests). Rebuilt each time the menu opens.
    func menuItems() -> [NSMenuItem]
}

public extension TactusModule {
    var permissions: [TactusPermission] { [] }
    func menuItems() -> [NSMenuItem] { [] }
}

public enum TactusPermission: String, CaseIterable, Sendable {
    /// Reading other apps' windows and controls (window snapping, button hover, access cues).
    case accessibility
    /// Capturing the screen or system audio (audio rumble, screen texture).
    case screenRecording

    public var title: String {
        switch self {
        case .accessibility: return "Accessibility"
        case .screenRecording: return "Screen & System Audio Recording"
        }
    }

    public var granted: Bool {
        switch self {
        case .accessibility: return AXIsProcessTrusted()
        case .screenRecording: return CGPreflightScreenCaptureAccess()
        }
    }

    /// Shows the system prompt (the first time) and opens the right Settings pane.
    public func request() {
        switch self {
        case .accessibility:
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
        case .screenRecording:
            _ = CGRequestScreenCaptureAccess()
        }
        let pane = self == .accessibility ? "Privacy_Accessibility" : "Privacy_ScreenCapture"
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Builds a menu item that runs a closure, so modules don't need @objc selectors for every option.
public final class ClosureMenuItem: NSMenuItem {
    private var handler: (() -> Void)?

    public init(_ title: String, checked: Bool? = nil, enabled: Bool = true, _ handler: (() -> Void)? = nil) {
        self.handler = handler
        super.init(title: title, action: handler == nil ? nil : #selector(fire), keyEquivalent: "")
        target = self
        if let checked { state = checked ? .on : .off }
        isEnabled = enabled && handler != nil
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func fire() { handler?() }
}
