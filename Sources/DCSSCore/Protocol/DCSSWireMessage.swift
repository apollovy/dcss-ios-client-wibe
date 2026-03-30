import Foundation

public enum DCSSConnectionState: Equatable, Sendable {
    case idle
    case connecting
    case connected
    case reconnecting(attempt: Int)
    case failed(reason: String)
}

public enum DCSSClientCommand: Equatable, Sendable {
    case handshake(clientVersion: String)
    case input(command: String)
    case heartbeat
}

public enum DCSSServerEvent: Equatable, Sendable {
    case hello(serverVersion: String)
    case gameFrame(grid: [String], statusLine: String)
    case message(text: String)
    case heartbeatAck
    case error(code: Int, text: String)
}

public struct DCSSWireEnvelope: Codable, Equatable, Sendable {
    public let type: String
    public let payload: [String: String]

    public init(type: String, payload: [String: String]) {
        self.type = type
        self.payload = payload
    }
}
