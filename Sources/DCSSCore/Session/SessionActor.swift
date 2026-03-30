import Foundation

public struct SessionDiagnostics: Equatable, Sendable {
    public var lastEventType: String?
    public var reconnectAttempt: Int?
    public var lastError: String?
    public var lastConnectedAt: Date?

    public init(lastEventType: String? = nil, reconnectAttempt: Int? = nil, lastError: String? = nil, lastConnectedAt: Date? = nil) {
        self.lastEventType = lastEventType
        self.reconnectAttempt = reconnectAttempt
        self.lastError = lastError
        self.lastConnectedAt = lastConnectedAt
    }
}

/// Swift fallback implementation of session + protocol codec.
///
/// Primary implementation is `RustSessionClient` from `DCSSCoreFFI` (FFI) — `SessionActor`
/// remains here to support builds where the Rust dynamic library is not present.
public actor SessionActor: SessionClient {
    private static let logPrefix = "[SessionActor]"
    private let transport: WebSocketTransporting
    private let codec: ProtocolCodec
    private let reconnectPolicy: ReconnectPolicy

    public private(set) var connectionState: DCSSConnectionState = .idle
    public private(set) var gameState = GameState()
    public private(set) var diagnostics = SessionDiagnostics()

    private var endpoint: URL?
    private var receiveTask: Task<Void, Never>?
    private var isInBackground = false

    public init(
        transport: WebSocketTransporting,
        codec: ProtocolCodec = .init(),
        reconnectPolicy: ReconnectPolicy = .init()
    ) {
        self.transport = transport
        self.codec = codec
        self.reconnectPolicy = reconnectPolicy
    }

    deinit {
        receiveTask?.cancel()
    }

    public func connect(url: URL, clientVersion: String? = nil) async {
        print("\(Self.logPrefix) connect start url=\(url.absoluteString)")
        endpoint = url
        connectionState = .connecting
        diagnostics.lastError = nil
        do {
            try await transport.connect(to: url)
            let resolvedClientVersion = clientVersion ?? "dcss-ios-0.1"
            let handshake = try codec.encode(command: .handshake(clientVersion: resolvedClientVersion))
            try await transport.send(handshake)
            connectionState = .connected
            diagnostics.lastConnectedAt = Date()
            diagnostics.reconnectAttempt = nil
            print("\(Self.logPrefix) connect success clientVersion=\(resolvedClientVersion)")
            startReceiveLoop()
        } catch {
            print("\(Self.logPrefix) connect failed error=\(error.localizedDescription)")
            connectionState = .failed(reason: error.localizedDescription)
            diagnostics.lastError = error.localizedDescription
        }
    }

    public func disconnect() async {
        print("\(Self.logPrefix) disconnect")
        receiveTask?.cancel()
        receiveTask = nil
        await transport.disconnect()
        connectionState = .idle
    }

    public func sendInput(_ command: String) async {
        guard !command.isEmpty else { return }
        do {
            let payload = try codec.encode(command: .input(command: command))
            try await transport.send(payload)
        } catch {
            diagnostics.lastError = error.localizedDescription
            connectionState = .failed(reason: error.localizedDescription)
        }
    }

    public func stateSnapshot() async -> (DCSSConnectionState, GameState, SessionDiagnostics) {
        (connectionState, gameState, diagnostics)
    }

    public func sendHeartbeat() async {
        do {
            try await transport.ping()
            let payload = try codec.encode(command: .heartbeat)
            try await transport.send(payload)
        } catch {
            diagnostics.lastError = error.localizedDescription
            await attemptReconnect(reason: error.localizedDescription)
        }
    }

    public func appDidEnterBackground() async {
        isInBackground = true
        receiveTask?.cancel()
        receiveTask = nil
        await transport.disconnect()
        if case .connected = connectionState {
            connectionState = .idle
        }
    }

    public func appWillEnterForeground() async {
        isInBackground = false
        guard case .idle = connectionState, let endpoint else { return }
        await connect(url: endpoint)
    }

    private func startReceiveLoop() {
        receiveTask?.cancel()
        receiveTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    let data = try await self.transport.receive()
                    let event = try self.codec.decode(data: data)
                    await self.apply(event: event)
                } catch {
                    await self.attemptReconnect(reason: error.localizedDescription)
                    return
                }
            }
        }
    }

    private func apply(event: DCSSServerEvent) async {
        diagnostics.lastEventType = String(describing: event)

        switch event {
        case .hello:
            break
        case .gameFrame(let grid, let statusLine):
            gameState.grid = grid
            gameState.statusLine = statusLine
        case .message(let text):
            gameState.lastMessage = text
        case .heartbeatAck:
            break
        case .heartbeatRequest:
            await sendHeartbeat()
        case .error(_, let text):
            diagnostics.lastError = text
            gameState.lastMessage = text
        case .unknown(let type):
            gameState.lastMessage = "Unknown event: \(type)"
        }
    }

    private func attemptReconnect(reason: String) async {
        guard let endpoint, !isInBackground else {
            print("\(Self.logPrefix) reconnect skipped reason=\(reason)")
            connectionState = .failed(reason: reason)
            diagnostics.lastError = reason
            return
        }

        for attempt in 1...reconnectPolicy.maxAttempts {
            diagnostics.reconnectAttempt = attempt
            connectionState = .reconnecting(attempt: attempt)
            let delaySeconds = reconnectPolicy.delay(for: attempt)
            print("\(Self.logPrefix) reconnect attempt=\(attempt) delay=\(delaySeconds)s reason=\(reason)")
            try? await Task.sleep(for: .seconds(delaySeconds))

            do {
                try await transport.connect(to: endpoint)
                connectionState = .connected
                diagnostics.lastConnectedAt = Date()
                diagnostics.reconnectAttempt = nil
                print("\(Self.logPrefix) reconnect success attempt=\(attempt)")
                startReceiveLoop()
                return
            } catch {
                print("\(Self.logPrefix) reconnect failed attempt=\(attempt) error=\(error.localizedDescription)")
                diagnostics.lastError = error.localizedDescription
                continue
            }
        }

        print("\(Self.logPrefix) reconnect exhausted reason=\(reason)")
        connectionState = .failed(reason: reason)
        diagnostics.lastError = reason
    }
}
