// Tactus · BridgeModule.swift
//
// Lets other programs play haptics: games, music software (Max, Pure Data, TouchDesigner, a DAW via OSC),
// scripts. They send short commands to UDP port 7477 on this Mac, as text, JSON or OSC. See
// docs/PROTOCOL.md, and try it from Terminal with `tactus send bump`.

import AppKit
import TactusCore

public final class BridgeModule: TactusModule {
    public let id = "bridge"
    public let title = "Bridge"
    public let summary = "Other apps send haptics over UDP/OSC (port 7477): games, Max, Pure Data, scripts"
    public private(set) var isRunning = false

    private let server: BridgeServer
    public var verbose = false
    public private(set) var problem: String?

    public init(port: UInt16 = BridgeServer.defaultPort) {
        server = BridgeServer(port: port)
        server.onCommand = { [weak self] c in
            if self?.verbose == true { print("bridge: \(c)") }
            Haptics.shared.perform(c)
        }
        server.onRejected = { [weak self] data in
            if self?.verbose == true { print("bridge: didn't understand \(String(decoding: data.prefix(80), as: UTF8.self))") }
        }
    }

    public func start() {
        guard !isRunning else { return }
        do {
            try server.start()
            isRunning = true
            problem = nil
        } catch {
            problem = "couldn't listen on port \(server.port): \(error)"
            print("tactus: bridge \(problem!)")
        }
    }

    public func stop() {
        server.stop()
        isRunning = false
        Haptics.shared.stopAll()
    }

    public func menuItems() -> [NSMenuItem] {
        let status = problem ?? server.lastError.map { "Error: \($0)" }
            ?? "Listening on 127.0.0.1:\(server.port) · \(server.received) commands so far"
        return [
            ClosureMenuItem(status, enabled: false),
            ClosureMenuItem("Copy a test command for Terminal") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("echo 'play heartbeat' | nc -u -w0 127.0.0.1 \(self.server.port)", forType: .string)
            },
        ]
    }
}
