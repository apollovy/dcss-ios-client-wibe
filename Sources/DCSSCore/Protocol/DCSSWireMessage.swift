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
    case heartbeatRequest
    case error(code: Int, text: String)
    case unknown(type: String)
}

public enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}

public struct DCSSWireEnvelope: Codable, Equatable, Sendable {
    public let type: String
    public let payload: [String: JSONValue]

    public init(type: String, payload: [String: JSONValue]) {
        self.type = type
        self.payload = payload
    }
}
