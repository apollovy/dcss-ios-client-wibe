import Foundation

public enum ProtocolCodecError: Error, Equatable {
    case invalidUTF8
    case unknownMessageType(String)
    case malformedPayload(String)
}

/// Swift fallback protocol codec for the MVP wire contract.
///
/// Note: the main wire/protocol path is implemented in Rust (`RustCore`) and consumed via
/// `RustSessionClient` (FFI) from `DCSSCoreFFI`. This codec stays to keep `SessionActor`
/// working when the Rust dynamic library cannot be loaded.
public struct ProtocolCodec: Sendable {
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private static let logPrefix = "[ProtocolCodec]"

    public init() {}

    public func encode(command: DCSSClientCommand) throws -> Data {
        let envelope: DCSSWireEnvelope
        switch command {
        case .handshake(let clientVersion):
            envelope = DCSSWireEnvelope(type: "handshake", payload: ["clientVersion": .string(clientVersion)])
        case .input(let command):
            envelope = DCSSWireEnvelope(type: "input", payload: ["command": .string(command)])
        case .heartbeat:
            envelope = DCSSWireEnvelope(type: "heartbeat", payload: [:])
        }
        return try encoder.encode(envelope)
    }

    public func decode(data: Data) throws -> DCSSServerEvent {
        guard let string = String(data: data, encoding: .utf8) else {
            throw ProtocolCodecError.invalidUTF8
        }

        if let envelope = try? decoder.decode(DCSSWireEnvelope.self, from: data) {
            let event = try decodeByType(type: envelope.type, payload: envelope.payload)
            print("\(Self.logPrefix) decoded envelope type=\(envelope.type) event=\(String(describing: event))")
            return event
        }

        // Compatibility mode for endpoints with flattened event payloads.
        if let raw = try JSONSerialization.jsonObject(with: Data(string.utf8)) as? [String: Any] {
            let type = (raw["type"] as? String) ?? (raw["msg"] as? String) ?? "unknown"
            let payload = jsonToValueMap(raw)
            let event = try decodeByType(type: type, payload: payload)
            print("\(Self.logPrefix) decoded flattened type=\(type) event=\(String(describing: event))")
            return event
        }

        throw ProtocolCodecError.malformedPayload("Cannot decode message")
    }

    private func decodeByType(type: String, payload: [String: JSONValue]) throws -> DCSSServerEvent {
        switch type {
        case "hello", "welcome":
            let version = payload.string("serverVersion") ?? payload.string("version") ?? "unknown"
            return .hello(serverVersion: version)
        case "frame", "update":
            let grid = parseGrid(from: payload)
            let statusLine = payload.string("statusLine") ?? payload.string("status") ?? ""
            return .gameFrame(grid: grid, statusLine: statusLine)
        case "message", "msg":
            guard let text = payload.string("text") ?? payload.string("message") else {
                throw ProtocolCodecError.malformedPayload("message requires text")
            }
            return .message(text: text)
        case "heartbeat_ack", "pong":
            return .heartbeatAck
        case "heartbeat", "ping":
            return .heartbeatRequest
        case "error":
            let code = payload.int("code") ?? -1
            let text = payload.string("text") ?? payload.string("message") ?? "unknown"
            return .error(code: code, text: text)
        default:
            return .unknown(type: type)
        }
    }

    private func parseGrid(from payload: [String: JSONValue]) -> [String] {
        if let gridRaw = payload.string("grid") {
            return gridRaw.components(separatedBy: "\\n")
        }
        if let rows = payload.stringArray("gridRows") {
            return rows
        }
        return []
    }

    private func jsonToValueMap(_ raw: [String: Any]) -> [String: JSONValue] {
        var result: [String: JSONValue] = [:]
        for (key, value) in raw {
            result[key] = toJSONValue(value)
        }
        return result
    }

    private func toJSONValue(_ value: Any) -> JSONValue {
        switch value {
        case let string as String:
            return .string(string)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            return .number(number.doubleValue)
        case let dict as [String: Any]:
            return .object(dict.mapValues { toJSONValue($0) })
        case let array as [Any]:
            return .array(array.map(toJSONValue))
        default:
            return .null
        }
    }
}

private extension Dictionary where Key == String, Value == JSONValue {
    func string(_ key: String) -> String? {
        guard case .string(let value)? = self[key] else { return nil }
        return value
    }

    func int(_ key: String) -> Int? {
        guard case .number(let value)? = self[key] else { return nil }
        return Int(value)
    }

    func stringArray(_ key: String) -> [String]? {
        guard case .array(let values)? = self[key] else { return nil }
        return values.compactMap {
            guard case .string(let value) = $0 else { return nil }
            return value
        }
    }
}
