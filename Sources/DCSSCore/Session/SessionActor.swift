import Foundation

public actor SessionActor {
    private let transport: WebSocketTransporting
    private let codec: ProtocolCodec
    private let reconnectPolicy: ReconnectPolicy

    public private(set) var connectionState: DCSSConnectionState = .idle
    public private(set) var gameState = GameState()

    private var endpoint: URL?
    private var receiveTask: Task<Void, Never>?

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

    public func connect(url: URL, clientVersion: String = "dcss-ios-0.1") async {
        endpoint = url
        connectionState = .connecting
        do {
            try await transport.connect(to: url)
            let handshake = try codec.encode(command: .handshake(clientVersion: clientVersion))
            try await transport.send(handshake)
            connectionState = .connected
            startReceiveLoop()
        } catch {
            connectionState = .failed(reason: error.localizedDescription)
        }
    }

    public func disconnect() async {
        receiveTask?.cancel()
        receiveTask = nil
        await transport.disconnect()
        connectionState = .idle
    }

    public func sendInput(_ command: String) async {
        do {
            let payload = try codec.encode(command: .input(command: command))
            try await transport.send(payload)
        } catch {
            connectionState = .failed(reason: error.localizedDescription)
        }
    }



    public func stateSnapshot() -> (DCSSConnectionState, GameState) {
        (connectionState, gameState)
    }

    public func sendHeartbeat() async {
        do {
            try await transport.ping()
            let payload = try codec.encode(command: .heartbeat)
            try await transport.send(payload)
        } catch {
            await attemptReconnect(reason: error.localizedDescription)
        }
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

    private func apply(event: DCSSServerEvent) {
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
        case .error(_, let text):
            gameState.lastMessage = text
        }
    }

    private func attemptReconnect(reason: String) async {
        guard let endpoint else {
            connectionState = .failed(reason: reason)
            return
        }

        for attempt in 1...reconnectPolicy.maxAttempts {
            connectionState = .reconnecting(attempt: attempt)
            let delaySeconds = reconnectPolicy.delay(for: attempt)
            try? await Task.sleep(for: .seconds(delaySeconds))

            do {
                try await transport.connect(to: endpoint)
                connectionState = .connected
                startReceiveLoop()
                return
            } catch {
                continue
            }
        }

        connectionState = .failed(reason: reason)
    }
}
