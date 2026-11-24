// Tactus · BridgeServer.swift
//
// Listens for commands from other programs (games, music software, scripts) on a UDP port on this Mac only.
// See docs/PROTOCOL.md for the commands; `tactus send` and examples/ show how to send them.

import Foundation
import Network

public final class BridgeServer {
    public static let defaultPort: UInt16 = 7477

    public let port: UInt16
    /// Called on the server's queue for every command received, with a short description of the sender.
    public var onCommand: ((TactusCommand) -> Void)?
    /// Called for datagrams that didn't parse (for --verbose).
    public var onRejected: ((Data) -> Void)?
    public private(set) var received = 0
    public private(set) var lastError: String?

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "tactus.bridge")

    public init(port: UInt16 = BridgeServer.defaultPort) { self.port = port }

    public var isListening: Bool { listener != nil }

    public func start() throws {
        guard listener == nil else { return }
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true
        // Only this Mac can send: bind to the loopback address.
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
        let l = try NWListener(using: params)
        l.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            conn.start(queue: self.queue)
            self.receive(on: conn)
        }
        l.stateUpdateHandler = { [weak self] state in
            if case .failed(let err) = state { self?.lastError = "\(err)"; self?.listener?.cancel(); self?.listener = nil }
        }
        l.start(queue: queue)
        listener = l
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    private func receive(on conn: NWConnection) {
        conn.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                let commands = CommandParser.parse(data)
                if commands.isEmpty { self.onRejected?(data) }
                for c in commands { self.received += 1; self.onCommand?(c) }
            }
            if error == nil { self.receive(on: conn) } else { conn.cancel() }
        }
    }

    /// Sends one datagram to a Tactus bridge on this Mac (used by `tactus send`). Returns false on failure.
    public static func send(_ data: Data, port: UInt16 = BridgeServer.defaultPort) -> Bool {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let sent = data.withUnsafeBytes { buf in
            withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, buf.baseAddress, buf.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        return sent == data.count
    }
}
