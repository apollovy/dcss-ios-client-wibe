import DCSSCore
import Foundation

actor MockWebSocketTransport: WebSocketTransporting {
    var connectCount = 0
    var sentPayloads: [Data] = []
    var receiveQueue: [Result<Data, Error>] = []
    var shouldFailConnectAttempts: Int = 0

    func enqueueReceive(_ item: Result<Data, Error>) {
        receiveQueue.append(item)
    }

    func connect(to url: URL) async throws {
        connectCount += 1
        if shouldFailConnectAttempts > 0 {
            shouldFailConnectAttempts -= 1
            throw URLError(.cannotConnectToHost)
        }
    }

    func disconnect() async {}

    func send(_ data: Data) async throws {
        sentPayloads.append(data)
    }

    func receive() async throws -> Data {
        guard !receiveQueue.isEmpty else {
            throw URLError(.networkConnectionLost)
        }
        let item = receiveQueue.removeFirst()
        return try item.get()
    }

    func ping() async throws {}
}
