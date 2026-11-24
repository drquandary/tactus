# Writing a module

A module turns something happening on the Mac into touch. It is a class that adopts `TactusModule` from `TactusCore`:

```swift
import AppKit
import TactusCore

public final class BatteryModule: TactusModule {
    public let id = "battery"                       // used on the command line: tactus run battery
    public let title = "Battery"                    // shown in the menu
    public let summary = "A heartbeat when the battery gets low"
    public private(set) var isRunning = false
    private var timer: Timer?

    public init() {}

    public func start() {                           // called on the main thread
        isRunning = true
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            if batteryIsLow() { Haptics.shared.play("heartbeat") }   // batteryIsLow(): your own check
        }
    }

    public func stop() {
        isRunning = false
        timer?.invalidate()
    }

    // Optional: options for the module's submenu, rebuilt each time the menu opens.
    public func menuItems() -> [NSMenuItem] {
        [ClosureMenuItem("Test it") { Haptics.shared.play("heartbeat", grace: 2) }]
    }
}
```

To include it, add the file to `Sources/TactusModules/` and add `BatteryModule()` to `allModules()` in `Sources/tactus/main.swift`.

## What TactusCore gives you

| | |
|---|---|
| `Haptics.shared.play("bump", level: 0.5)` | Play a named pattern. It checks that a finger is on the pad and applies the overall strength. |
| `Haptics.shared.play(Pattern.parse("230:9:0.5/55,230:9:0.5")!)` | Play any pattern. |
| `Haptics.shared.play(Pulse(hz: 150, ms: 20, level: 1))` | Play one tone. |
| `Haptics.shared.hold("rain", hz: 90, level: 0.3, ttlMS: 200)` and `release("rain")` | A steady vibration from a named source. |
| `light: true` | Marks frequent, low-priority cues (hover, scroll). These are dropped if one played less than 30 ms ago. |
| `grace:` | How long after the finger lifts a cue may still play. Use about 0.8 for things that happen as you let go, like a window snap. |
| `Trackpad.shared.fingerDown` | Whether a finger is on the pad right now. |
| `AX` | Accessibility helpers: `AX.cue(for:)`, `AX.frame(_:)`, `AX.pointer()`, `AX.FrontmostObserver`. |
| `TextureEngine`, `BassDetector`, `MIDIParser`, `BeatCounter`, `RoleCue` | The signal logic the built-in modules use. Each is pure Swift and unit tested. |
| `TactusPermission.accessibility` / `.screenRecording` | List them in `permissions`. The menu offers to grant any that are missing. |

## Guidelines

- **Keep cues short.** Most patterns are 10 to 40 ms. Long or constant vibration gets tiring and drowns out other cues.
- **Leave a gap.** If something can fire many times a second, mark it `light: true` or rate-limit it yourself.
- **Use the feelable range.** Fingertips feel about 65 to 400 Hz, best near 250 Hz.
- **Don't block the main thread.** Accessibility calls into a slow app can take a while. Do frequent polling on your own queue, like the built-in `HoverWatcher`.
- **Put pure logic in TactusCore with tests.** It runs on any platform, so `swift test` covers it.

## Using TactusCore in your own app

Tactus is a Swift package, so another app can depend on the `TactusCore` library and call `Trackpad.shared.open()` and `Haptics.shared.play(...)` directly, without the menu bar host. Be aware that TactusCore drives the trackpad through a private macOS framework. Apps that use it can't go on the Mac App Store, and a macOS update could break them.
