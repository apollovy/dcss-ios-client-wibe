import DCSSCore
import Foundation
import XCTest

final class SessionActorTests: XCTestCase {
    func testConnectSendsHandshake() async throws {
        let transport = MockWebSocketTransport()
        let session = SessionActor(transport: transport)

        await session.connect(url: URL(string: "wss://example.com/socket")!)

        let sent = await transport.sentPayloads
        XCTAssertEqual(sent.count, 1)

        let envelope = try JSONDecoder().decode(DCSSWireEnvelope.self, from: sent[0])
        XCTAssertEqual(envelope.type, "handshake")
    }

    func testReconnectAfterReceiveFailure() async throws {
        let transport = MockWebSocketTransport()
        await transport.enqueueReceive(.failure(URLError(.networkConnectionLost)))

        let session = SessionActor(
            transport: transport,
            reconnectPolicy: ReconnectPolicy(maxAttempts: 2, baseDelay: 0.01)
        )

        await session.connect(url: URL(string: "wss://example.com/socket")!)
        try? await Task.sleep(for: .milliseconds(120))

        let state = await session.connectionState
        switch state {
        case .connected, .reconnecting:
            XCTAssertTrue(true)
        default:
            XCTFail("Expected reconnect flow, got \(state)")
        }
    }

    func testBackgroundStopsSessionAndForegroundReconnects() async throws {
        let transport = MockWebSocketTransport()
        let session = SessionActor(transport: transport)

        await session.connect(url: URL(string: "wss://example.com/socket")!)
        await session.appDidEnterBackground()
        let idleState = await session.connectionState
        XCTAssertEqual(idleState, .idle)

        await session.appWillEnterForeground()
        let connectCount = await transport.connectCount
        XCTAssertGreaterThanOrEqual(connectCount, 2)
    }
}
