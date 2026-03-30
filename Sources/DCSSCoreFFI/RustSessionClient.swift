import Foundation
import DCSSCore

import Darwin

private struct DCSSSessionHandle: @unchecked Sendable {
    let raw: UnsafeMutableRawPointer
}

private struct CoreAPILoader {
    let libHandle: UnsafeMutableRawPointer

    let sessionCreate: @convention(c) () -> UnsafeMutableRawPointer?
    let sessionDestroy: @convention(c) (UnsafeMutableRawPointer?) -> Void

    let sessionConnect: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Void
    let sessionDisconnect: @convention(c) (UnsafeMutableRawPointer?) -> Void
    let sessionSendInput: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> Void
    let sessionSendHeartbeat: @convention(c) (UnsafeMutableRawPointer?) -> Void

    let sessionDidEnterBackground: @convention(c) (UnsafeMutableRawPointer?) -> Void
    let sessionWillEnterForeground: @convention(c) (UnsafeMutableRawPointer?) -> Void

    let sessionGetSnapshotJSON: @convention(c) (UnsafeMutableRawPointer?) -> UnsafeMutablePointer<CChar>?
    let freeString: @convention(c) (UnsafeMutablePointer<CChar>?) -> Void

    static func load() -> CoreAPILoader? {
        let candidates: [String] = {
            var list: [String] = []
            if let env = ProcessInfo.processInfo.environment["DCSS_CORE_LIB_PATH"] {
                list.append(env)
            }
            // Typical dev paths (best-effort).
            list.append("./libdcss_core.dylib")
            list.append("../RustCore/target/debug/libdcss_core.dylib")
            list.append("../RustCore/target/release/libdcss_core.dylib")
            return list
        }()

        // Also try bare name to let loader resolve it via rpath.
        let fallbackNames = ["libdcss_core.dylib", "libdcss_core.so"]

        func resolveSymbol<T>(_ symbol: String, _ lib: UnsafeMutableRawPointer) -> T? {
            guard let sym = dlsym(lib, symbol) else { return nil }
            return unsafeBitCast(sym, to: T.self)
        }

        for path in candidates + fallbackNames {
            // RTLD_NOW avoids lazy symbol resolution failures at first call.
            guard let handle = dlopen(path, RTLD_NOW) else { continue }

            guard
                let sessionCreate: @convention(c) () -> UnsafeMutableRawPointer? =
                    resolveSymbol("dcss_session_create", handle),
                let sessionDestroy: @convention(c) (UnsafeMutableRawPointer?) -> Void =
                    resolveSymbol("dcss_session_destroy", handle),
                let sessionConnect: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Void =
                    resolveSymbol("dcss_session_connect", handle),
                let sessionDisconnect: @convention(c) (UnsafeMutableRawPointer?) -> Void =
                    resolveSymbol("dcss_session_disconnect", handle),
                let sessionSendInput: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> Void =
                    resolveSymbol("dcss_session_send_input", handle),
                let sessionSendHeartbeat: @convention(c) (UnsafeMutableRawPointer?) -> Void =
                    resolveSymbol("dcss_session_send_heartbeat", handle),
                let sessionDidEnterBackground: @convention(c) (UnsafeMutableRawPointer?) -> Void =
                    resolveSymbol("dcss_session_app_did_enter_background", handle),
                let sessionWillEnterForeground: @convention(c) (UnsafeMutableRawPointer?) -> Void =
                    resolveSymbol("dcss_session_app_will_enter_foreground", handle),
                let sessionGetSnapshotJSON: @convention(c) (UnsafeMutableRawPointer?) -> UnsafeMutablePointer<CChar>? =
                    resolveSymbol("dcss_session_get_snapshot_json", handle),
                let freeString: @convention(c) (UnsafeMutablePointer<CChar>?) -> Void =
                    resolveSymbol("dcss_free_string", handle)
            else {
                dlclose(handle)
                continue
            }

            return CoreAPILoader(
                libHandle: handle,
                sessionCreate: sessionCreate,
                sessionDestroy: sessionDestroy,
                sessionConnect: sessionConnect,
                sessionDisconnect: sessionDisconnect,
                sessionSendInput: sessionSendInput,
                sessionSendHeartbeat: sessionSendHeartbeat,
                sessionDidEnterBackground: sessionDidEnterBackground,
                sessionWillEnterForeground: sessionWillEnterForeground,
                sessionGetSnapshotJSON: sessionGetSnapshotJSON,
                freeString: freeString
            )
        }

        return nil
    }
}

extension CoreAPILoader: @unchecked Sendable {}

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
    private let api: CoreAPILoader
    private let handle: DCSSSessionHandle

    public static func makeOrNil() -> RustSessionClient? {
        guard let api = CoreAPILoader.load() else { return nil }
        guard let rawHandle = api.sessionCreate() else { return nil }
        return RustSessionClient(api: api, handle: DCSSSessionHandle(raw: rawHandle))
    }

    private init(api: CoreAPILoader, handle: DCSSSessionHandle) {
        self.api = api
        self.handle = handle
    }

    deinit {
        api.sessionDestroy(handle.raw)
        dlclose(api.libHandle)
    }

    public func connect(url: URL, clientVersion: String?) async {
        let urlStr = url.absoluteString
        urlStr.withCString { urlC in
            if let clientVersion {
                clientVersion.withCString { clientC in
                    api.sessionConnect(handle.raw, urlC, clientC)
                }
            } else {
                api.sessionConnect(handle.raw, urlC, nil)
            }
        }
    }

    public func disconnect() async {
        api.sessionDisconnect(handle.raw)
    }

    public func sendInput(_ command: String) async {
        command.withCString { c in
            api.sessionSendInput(handle.raw, c)
        }
    }

    public func sendHeartbeat() async {
        api.sessionSendHeartbeat(handle.raw)
    }

    public func appDidEnterBackground() async {
        api.sessionDidEnterBackground(handle.raw)
    }

    public func appWillEnterForeground() async {
        api.sessionWillEnterForeground(handle.raw)
    }

    public func stateSnapshot() async -> (DCSSConnectionState, GameState, SessionDiagnostics) {
        let snapshotPtr = api.sessionGetSnapshotJSON(handle.raw)
        guard let snapshotPtr else {
            let conn: DCSSConnectionState = .failed(reason: "core snapshot unavailable")
            return (conn, GameState(), SessionDiagnostics(lastEventType: nil, reconnectAttempt: nil, lastError: "core missing", lastConnectedAt: nil))
        }

        let json = String(cString: snapshotPtr)
        api.freeString(snapshotPtr)
        return RustSnapshotMapper.mapSnapshotJSON(json)
    }
}

