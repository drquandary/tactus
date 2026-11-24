// Tactus · Accessibility.swift
//
// Small helpers for reading other apps' windows and controls through the macOS Accessibility API.

import AppKit
import ApplicationServices

public enum AX {
    public static func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
    }

    public static func string(_ el: AXUIElement, _ name: String) -> String? { attr(el, name) as? String }

    public static func parent(_ el: AXUIElement) -> AXUIElement? {
        guard let p = attr(el, kAXParentAttribute), CFGetTypeID(p) == AXUIElementGetTypeID() else { return nil }
        return (p as! AXUIElement)
    }

    /// An element's frame in global display coordinates (top-left origin).
    public static func frame(_ el: AXUIElement) -> CGRect? {
        guard let pv = attr(el, kAXPositionAttribute), let sv = attr(el, kAXSizeAttribute),
              CFGetTypeID(pv) == AXValueGetTypeID(), CFGetTypeID(sv) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        guard AXValueGetValue(pv as! AXValue, .cgPoint, &p), AXValueGetValue(sv as! AXValue, .cgSize, &s) else { return nil }
        return CGRect(origin: p, size: s)
    }

    /// The pattern name for this element or one of its first few ancestors (labels and icons often sit inside
    /// their control), with the element that matched.
    public static func cue(for start: AXUIElement, depth: Int = 3) -> (element: AXUIElement, pattern: String)? {
        var el = start
        for _ in 0..<depth {
            if let role = string(el, kAXRoleAttribute) {
                let sub = string(el, kAXSubroleAttribute)
                var checked: Bool?
                if ["AXCheckBox", "AXRadioButton", "AXSwitch"].contains(role) {
                    checked = (attr(el, kAXValueAttribute) as? NSNumber)?.intValue == 1
                }
                if let name = RoleCue.patternName(role: role, subrole: sub, checked: checked) { return (el, name) }
            }
            guard let p = parent(el) else { return nil }
            el = p
        }
        return nil
    }

    /// The pointer's position in global display coordinates (top-left origin), as Accessibility uses.
    public static func pointer() -> CGPoint? { CGEvent(source: nil)?.location }

    /// A screen's visible area (no menu bar or Dock) in top-left coordinates.
    public static func visibleFrame(_ screen: NSScreen) -> CGRect {
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        let v = screen.visibleFrame
        return CGRect(x: v.minX, y: primaryTop - v.maxY, width: v.width, height: v.height)
    }

    /// A screen's whole area in top-left coordinates.
    public static func fullFrame(_ screen: NSScreen) -> CGRect {
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        let f = screen.frame
        return CGRect(x: f.minX, y: primaryTop - f.maxY, width: f.width, height: f.height)
    }

    /// Watches one app at a time (the frontmost) for Accessibility notifications, and follows app switches.
    public final class FrontmostObserver {
        public typealias Handler = (_ element: AXUIElement, _ notification: String) -> Void
        private let notifications: [String]
        private let handler: Handler
        private var observer: AXObserver?
        private var pid: pid_t = 0
        private var token: NSObjectProtocol?

        public init(notifications: [String], handler: @escaping Handler) {
            self.notifications = notifications
            self.handler = handler
        }

        public func start() {
            token = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
                self?.follow()
            }
            follow()
        }

        public func stop() {
            if let token { NSWorkspace.shared.notificationCenter.removeObserver(token) }
            token = nil
            detach()
        }

        /// Starts observing the frontmost app if it changed (call again after Accessibility is granted).
        public func follow() {
            guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication else { return }
            let p = app.processIdentifier
            guard p != pid, p != getpid() else { return }
            detach()
            pid = p
            var obs: AXObserver?
            let callback: AXObserverCallback = { _, element, note, refcon in
                guard let refcon else { return }
                let me = Unmanaged<FrontmostObserver>.fromOpaque(refcon).takeUnretainedValue()
                me.handler(element, note as String)
            }
            guard AXObserverCreate(p, callback, &obs) == .success, let obs else { return }
            let appEl = AXUIElementCreateApplication(p)
            let me = Unmanaged.passUnretained(self).toOpaque()
            for n in notifications { AXObserverAddNotification(obs, appEl, n as CFString, me) }
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
            observer = obs
        }

        private func detach() {
            if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode) }
            observer = nil
            pid = 0
        }
    }
}
