import Foundation
import DCSSCore

// Прямые C-ABI функции, реализованные в Rust (`RustCore/src/lib.rs`).
// Эти символы будут найдены линкером, когда libdcss_core.a / XCFramework
// подключены к таргету Xcode.
@_silgen_name("dcss_session_create")
private func dcss_session_create() -> UnsafeMutableRawPointer?

@_silgen_name("dcss_session_destroy")
private func dcss_session_destroy(_ handle: UnsafeMutableRawPointer?)

@_silgen_name("dcss_session_connect")
private func dcss_session_connect(
    _ handle: UnsafeMutableRawPointer?,
    _ url: UnsafePointer<CChar>?,
    _ clientVersion: UnsafePointer<CChar>?
)

@_silgen_name("dcss_session_disconnect")
private func dcss_session_disconnect(_ handle: UnsafeMutableRawPointer?)

@_silgen_name("dcss_session_send_input")
private func dcss_session_send_input(_ handle: UnsafeMutableRawPointer?, _ command: UnsafePointer<CChar>?)

@_silgen_name("dcss_session_send_heartbeat")
private func dcss_session_send_heartbeat(_ handle: UnsafeMutableRawPointer?)

@_silgen_name("dcss_session_app_did_enter_background")
private func dcss_session_app_did_enter_background(_ handle: UnsafeMutableRawPointer?)

@_silgen_name("dcss_session_app_will_enter_foreground")
private func dcss_session_app_will_enter_foreground(_ handle: UnsafeMutableRawPointer?)

@_silgen_name("dcss_session_get_snapshot_json")
private func dcss_session_get_snapshot_json(_ handle: UnsafeMutableRawPointer?) -> UnsafeMutablePointer<CChar>?

@_silgen_name("dcss_free_string")
private func dcss_free_string(_ ptr: UnsafeMutablePointer<CChar>?)

private struct DCSSSessionHandle: @unchecked Sendable {
    let raw: UnsafeMutableRawPointer
}

private struct RustSnapshot: Decodable {
    struct ConnectionStateRepr: Decodable {
        let type: String
        let attempt: Int?
        let reason: String?
    }

    struct GameStateRepr: Decodable {
        let grid: [String]
        let statusLine: String
        let lastMessage: String
    }

    struct DiagnosticsRepr: Decodable {
        let lastEventType: String?
        let reconnectAttempt: Int?
        let lastError: String?
        let lastConnectedAt: String?
    }

    let connectionState: ConnectionStateRepr
    let gameState: GameStateRepr
    let diagnostics: DiagnosticsRepr
}

public enum RustSnapshotMapper {
    public static func mapSnapshotJSON(_ json: String) -> (DCSSConnectionState, GameState, SessionDiagnostics) {
        guard let data = json.data(using: .utf8) else {
            return (
                .failed(reason: "core snapshot invalid utf8"),
                GameState(),
                SessionDiagnostics(lastEventType: nil, reconnectAttempt: nil, lastError: "invalid utf8", lastConnectedAt: nil),
            )
        }

        do {
            let decoder = JSONDecoder()
            let snap = try decoder.decode(RustSnapshot.self, from: data)

            let connection: DCSSConnectionState = {
                switch snap.connectionState.type {
                case "idle":
                    return .idle
                case "connecting":
                    return .connecting
                case "connected":
                    return .connected
                case "reconnecting":
                    return .reconnecting(attempt: snap.connectionState.attempt ?? 0)
                case "failed":
                    return .failed(reason: snap.connectionState.reason ?? "unknown")
                default:
                    return .failed(reason: "unknown connection state: \(snap.connectionState.type)")
                }
            }()

            let formatter = ISO8601DateFormatter()
            let lastConnectedAt = snap.diagnostics.lastConnectedAt.flatMap { formatter.date(from: $0) }

            let diagnostics = SessionDiagnostics(
                lastEventType: snap.diagnostics.lastEventType,
                reconnectAttempt: snap.diagnostics.reconnectAttempt,
                lastError: snap.diagnostics.lastError,
                lastConnectedAt: lastConnectedAt
            )

            let game = GameState(
                grid: snap.gameState.grid,
                statusLine: snap.gameState.statusLine,
                lastMessage: snap.gameState.lastMessage
            )

            return (connection, game, diagnostics)
        } catch {
            return (
                .failed(reason: "core snapshot decode error"),
                GameState(),
                SessionDiagnostics(lastEventType: nil, reconnectAttempt: nil, lastError: String(describing: error), lastConnectedAt: nil)
            )
        }
    }
}

public actor RustSessionClient: SessionClient {
    private static let logPrefix = "[RustSessionClient]"
    private let handle: DCSSSessionHandle

    public static func makeOrNil() -> RustSessionClient? {
        guard let rawHandle = dcss_session_create() else { return nil }
        return RustSessionClient(handle: DCSSSessionHandle(raw: rawHandle))
    }

    private init(handle: DCSSSessionHandle) {
        self.handle = handle
    }

    deinit {
        dcss_session_destroy(handle.raw)
    }

    public func connect(url: URL, clientVersion: String?) async {
        let urlStr = url.absoluteString
        print("\(Self.logPrefix) connect start url=\(urlStr) clientVersion=\(clientVersion ?? "nil")")
        urlStr.withCString { urlC in
            if let clientVersion {
                clientVersion.withCString { clientC in
                    dcss_session_connect(handle.raw, urlC, clientC)
                }
            } else {
                dcss_session_connect(handle.raw, urlC, nil)
            }
        }
        print("\(Self.logPrefix) connect called")
    }

    public func disconnect() async {
        print("\(Self.logPrefix) disconnect")
        dcss_session_disconnect(handle.raw)
    }

    public func sendInput(_ command: String) async {
        print("\(Self.logPrefix) send input=\(command)")
        command.withCString { c in
            dcss_session_send_input(handle.raw, c)
        }
    }

    public func sendHeartbeat() async {
        dcss_session_send_heartbeat(handle.raw)
    }

    public func appDidEnterBackground() async {
        dcss_session_app_did_enter_background(handle.raw)
    }

    public func appWillEnterForeground() async {
        dcss_session_app_will_enter_foreground(handle.raw)
    }

    public func stateSnapshot() async -> (DCSSConnectionState, GameState, SessionDiagnostics) {
        let snapshotPtr = dcss_session_get_snapshot_json(handle.raw)
        guard let snapshotPtr else {
            print("\(Self.logPrefix) snapshot unavailable")
            let conn: DCSSConnectionState = .failed(reason: "core snapshot unavailable")
            return (conn, GameState(), SessionDiagnostics(lastEventType: nil, reconnectAttempt: nil, lastError: "core missing", lastConnectedAt: nil))
        }

        let json = String(cString: snapshotPtr)
        dcss_free_string(snapshotPtr)
        let snapshot = RustSnapshotMapper.mapSnapshotJSON(json)
        print("\(Self.logPrefix) decoded snapshot state=\(String(describing: snapshot.0)) lastEvent=\(snapshot.2.lastEventType ?? "-") lastError=\(snapshot.2.lastError ?? "-")")
        return snapshot
    }
}

