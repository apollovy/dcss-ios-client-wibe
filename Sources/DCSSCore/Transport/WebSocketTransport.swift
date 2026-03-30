import Foundation

public protocol WebSocketTransporting: Sendable {
    func connect(to url: URL) async throws
    func disconnect() async
    func send(_ data: Data) async throws
    func receive() async throws -> Data
    func ping() async throws
}

public final class WebSocketTransport: NSObject, WebSocketTransporting, @unchecked Sendable {
    private let session: URLSession
    private var task: URLSessionWebSocketTask?

    public override init() {
        self.session = URLSession(configuration: .default)
        super.init()
    }

    public func connect(to url: URL) async throws {
        let socketTask = session.webSocketTask(with: url)
        socketTask.resume()
        self.task = socketTask
    }

    public func disconnect() async {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    public func send(_ data: Data) async throws {
        guard let task else { throw URLError(.notConnectedToInternet) }
        try await task.send(.data(data))
    }

    public func receive() async throws -> Data {
        guard let task else { throw URLError(.notConnectedToInternet) }
        let msg = try await task.receive()
        switch msg {
        case .data(let data):
            return data
        case .string(let string):
            return Data(string.utf8)
        @unknown default:
            return Data()
        }
    }

    public func ping() async throws {
        guard let task else { throw URLError(.notConnectedToInternet) }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            task.sendPing { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }
}
