import Foundation

public enum ProtocolCodecError: Error, Equatable {
    case invalidUTF8
    case unknownMessageType(String)
    case malformedPayload(String)
}

public struct ProtocolCodec: Sendable {
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    public init() {}

    public func encode(command: DCSSClientCommand) throws -> Data {
        let envelope: DCSSWireEnvelope
        switch command {
        case .handshake(let clientVersion):
            envelope = DCSSWireEnvelope(type: "handshake", payload: ["clientVersion": clientVersion])
        case .input(let command):
            envelope = DCSSWireEnvelope(type: "input", payload: ["command": command])
        case .heartbeat:
            envelope = DCSSWireEnvelope(type: "heartbeat", payload: [:])
        }
        return try encoder.encode(envelope)
    }

    public func decode(data: Data) throws -> DCSSServerEvent {
        guard let _ = String(data: data, encoding: .utf8) else {
            throw ProtocolCodecError.invalidUTF8
        }

        let envelope = try decoder.decode(DCSSWireEnvelope.self, from: data)
        switch envelope.type {
        case "hello":
            guard let version = envelope.payload["serverVersion"] else {
                throw ProtocolCodecError.malformedPayload("hello requires serverVersion")
            }
            return .hello(serverVersion: version)
        case "frame":
            guard let gridRaw = envelope.payload["grid"],
                  let statusLine = envelope.payload["statusLine"] else {
                throw ProtocolCodecError.malformedPayload("frame requires grid/statusLine")
            }
            return .gameFrame(grid: gridRaw.components(separatedBy: "\\n"), statusLine: statusLine)
        case "message":
            guard let text = envelope.payload["text"] else {
                throw ProtocolCodecError.malformedPayload("message requires text")
            }
            return .message(text: text)
        case "heartbeat_ack":
            return .heartbeatAck
        case "error":
            let code = Int(envelope.payload["code"] ?? "-1") ?? -1
            let text = envelope.payload["text"] ?? "unknown"
            return .error(code: code, text: text)
        default:
            throw ProtocolCodecError.unknownMessageType(envelope.type)
        }
    }
}
