// Tactus · the command-line tool and menu bar host
//
//   tactus                      start the menu bar app with the modules you had on last time
//   tactus run <module> …       start it with just these modules (signals access music games bridge)
//   tactus texture [image]      the texture window: feel an image
//   tactus send <command>       send a command to a running Tactus (e.g. `tactus send play bump 0.8`)
//   tactus patterns             list the named patterns
//   tactus modules              list the modules
//   tactus selftest             check the motor and finger detection
//
//   options: --external (use a Magic Trackpad), --verbose (print what plays), --port <n> (bridge port),
//            --always (play with no finger on the pad), --tick <ms> (texture window)

import AppKit
import TactusCore
import TactusModules

setvbuf(stdout, nil, _IOLBF, 0)

var args = Array(CommandLine.arguments.dropFirst())
var external = false, verbose = false, always = false
var port = BridgeServer.defaultPort
var tickMS = 10.0

func fail(_ s: String) -> Never { FileHandle.standardError.write(("tactus: " + s + "\n").data(using: .utf8)!); exit(64) }

// Global options can go anywhere.
var rest: [String] = []
while !args.isEmpty {
    let a = args.removeFirst()
    switch a {
    case "--external": external = true
    case "--verbose", "-v": verbose = true
    case "--always": always = true
    case "--port":
        guard let v = args.first.flatMap(UInt16.init) else { fail("--port needs a port number") }
        port = v; args.removeFirst()
    case "--tick":
        guard let v = args.first.flatMap(Double.init), v >= 2, v <= 100 else { fail("--tick needs milliseconds from 2 to 100") }
        tickMS = v; args.removeFirst()
    case "-h", "--help", "help":
        print("""
        Tactus: haptics for the Mac trackpad.

          tactus                      menu bar app (modules you had on last time)
          tactus run <module> …       menu bar app with just these modules
          tactus texture [image]      feel an image in a window
          tactus send <command>       send a command to a running Tactus, e.g. tactus send play bump 0.8
          tactus patterns             list the named patterns
          tactus modules              list the modules
          tactus selftest             check the motor and finger detection

          --external  use a Magic Trackpad    --verbose  print what plays    --port <n>  bridge port (7477)
          --always    play even with no finger on the trackpad (for keyboard users, or testing)
        """)
        exit(0)
    default: rest.append(a)
    }
}

func allModules() -> [TactusModule] {
    [SignalsModule(), AccessModule(), MusicModule(), GamesModule(), BridgeModule(port: port)]
}

let command = rest.first ?? "run"
let operands = Array(rest.dropFirst())

switch command {
case "patterns":
    for name in Pattern.names {
        let p = Pattern.named(name)!
        let spec = p.pulses.map { String(format: "%g:%g:%g", $0.hz, $0.ms, $0.level) + ($0.gapMS > 0 ? String(format: "/%g", $0.gapMS) : "") }
        print(name.padding(toLength: 11, withPad: " ", startingAt: 0), spec.joined(separator: ", "))
    }
    exit(0)

case "modules":
    for m in allModules() {
        let needs = m.permissions.isEmpty ? "" : "  [needs: \(m.permissions.map(\.title).joined(separator: ", "))]"
        print(m.id.padding(toLength: 9, withPad: " ", startingAt: 0), m.summary + needs)
    }
    exit(0)

case "send":
    guard !operands.isEmpty else { fail("send what? e.g. tactus send play bump 0.8") }
    let text = operands.joined(separator: " ")
    guard !CommandParser.parse(Data(text.utf8)).isEmpty else { fail("not a command Tactus understands: \(text) (see docs/PROTOCOL.md)") }
    guard BridgeServer.send(Data(text.utf8), port: port) else { fail("couldn't send to port \(port)") }
    print("sent: \(text)")
    exit(0)

case "selftest":
    guard Trackpad.shared.open(external: external) else { fail(Trackpad.shared.problem) }
    print("selftest: rest a finger on the trackpad. You should feel one bump a second for 5 seconds.")
    var wasDown = false
    let end = Clock.now() + 5
    var next = Clock.now()
    var played = 0
    while Clock.now() < end {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
        let down = Trackpad.shared.fingerDown
        if down != wasDown { print(String(format: "selftest: %.2f s finger %@", Clock.now(), down ? "down" : "up")); wasDown = down }
        if Clock.now() >= next { Trackpad.shared.playTone(hz: 150, ms: 20, level: 1); played += 1; next += 1 }
    }
    print("selftest: motor open, \(played) bumps played, finger data \(Trackpad.shared.touchWorking ? "received" : "never received").")
    Trackpad.shared.close()
    exit(0)

case "texture":
    if !Trackpad.shared.open(external: external) { print("tactus: \(Trackpad.shared.problem). The window will open, but nothing will vibrate.") }
    TextureApp.run(imagePath: operands.first, tickMS: tickMS)

case "run":
    if !Trackpad.shared.open(external: external) { print("tactus: \(Trackpad.shared.problem). It will run, but nothing will vibrate.") }
    else { print("tactus: trackpad ready.") }
    if verbose { Haptics.shared.log = { print("haptics: " + $0) } }
    if always { Haptics.shared.requireFinger = false }
    let modules = allModules()
    for case let b as BridgeModule in modules { b.verbose = verbose }
    let ids = Set(modules.map(\.id))
    for o in operands where !ids.contains(o) { fail("no module called \(o). Modules: \(modules.map(\.id).joined(separator: ", "))") }
    let host = ModuleHost(modules: modules, onlyThese: operands.isEmpty ? nil : Set(operands))
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.delegate = host
    app.run()

default:
    fail("unknown command \(command). Try tactus --help.")
}

// MARK: - The menu bar host

final class ModuleHost: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let modules: [TactusModule]
    let onlyThese: Set<String>?
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let defaultsKey = "enabledModules"
    let defaultOn: Set<String> = ["signals", "music", "bridge"]

    init(modules: [TactusModule], onlyThese: Set<String>?) {
        self.modules = modules
        self.onlyThese = onlyThese
    }

    var enabled: Set<String> {
        get {
            if let onlyThese { return onlyThese }
            if let saved = UserDefaults.standard.array(forKey: defaultsKey) as? [String] { return Set(saved) }
            return defaultOn
        }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: defaultsKey) }
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        if let image = NSImage(systemSymbolName: "hand.tap", accessibilityDescription: "Tactus") {
            statusItem.button?.image = image
        } else {
            statusItem.button?.title = "Tactus"
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        let on = enabled
        for m in modules where on.contains(m.id) { m.start() }
        let names = modules.filter { $0.isRunning }.map(\.id).joined(separator: ", ")
        print("tactus: running in the menu bar (the hand icon) with: \(names.isEmpty ? "no modules" : names). Quit from the menu or with Ctrl-C.")
        let missing = Set(modules.filter(\.isRunning).flatMap(\.permissions)).filter { !$0.granted }
        if !missing.isEmpty {
            print("tactus: some features need permission: \(missing.map(\.title).sorted().joined(separator: ", ")). Use the menu's permission items.")
        }
    }

    func applicationWillTerminate(_ note: Notification) {
        for m in modules where m.isRunning { m.stop() }
        Trackpad.shared.close()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(ClosureMenuItem("Tactus", enabled: false))
        if !Trackpad.shared.isReady { menu.addItem(ClosureMenuItem("Motor: \(Trackpad.shared.problem)", enabled: false)) }
        menu.addItem(.separator())
        for m in modules {
            let item = NSMenuItem(title: m.title, action: nil, keyEquivalent: "")
            item.state = m.isRunning ? .on : .off
            let sub = NSMenu()
            sub.addItem(ClosureMenuItem(m.summary, enabled: false))
            sub.addItem(ClosureMenuItem(m.isRunning ? "Turn off" : "Turn on") { [weak self] in self?.toggle(m) })
            let missing = m.permissions.filter { !$0.granted }
            for p in missing { sub.addItem(ClosureMenuItem("Grant \(p.title) permission…") { p.request() }) }
            let extra = m.menuItems()
            if !extra.isEmpty { sub.addItem(.separator()); extra.forEach(sub.addItem) }
            item.submenu = sub
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let h = Haptics.shared
        menu.addItem(ClosureMenuItem(String(format: "Strength %.1f", h.gain), enabled: false))
        menu.addItem(ClosureMenuItem("Stronger") { h.gain += 0.1 })
        menu.addItem(ClosureMenuItem("Weaker") { h.gain -= 0.1 })
        menu.addItem(ClosureMenuItem("Only when a finger is on the trackpad", checked: h.requireFinger) { h.requireFinger.toggle() })
        menu.addItem(ClosureMenuItem("Pause everything", checked: h.paused) { h.paused.toggle() })
        let tryItem = NSMenuItem(title: "Try a pattern", action: nil, keyEquivalent: "")
        let tryMenu = NSMenu()
        for name in Pattern.names { tryMenu.addItem(ClosureMenuItem(name) { h.play(name, grace: 2) }) }
        tryItem.submenu = tryMenu
        menu.addItem(tryItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Tactus", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    func toggle(_ m: TactusModule) {
        var on = enabled
        if m.isRunning { m.stop(); on.remove(m.id) } else { m.start(); on.insert(m.id) }
        if onlyThese == nil { enabled = on }
    }
}
