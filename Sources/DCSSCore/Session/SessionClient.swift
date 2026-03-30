import Foundation

public protocol SessionClient: Sendable {
    func connect(url: URL, clientVersion: String?) async
    func disconnect() async
    func sendInput(_ command: String) async
    func sendHeartbeat() async
    func appDidEnterBackground() async
    func appWillEnterForeground() async

    func stateSnapshot() async -> (DCSSConnectionState, GameState, SessionDiagnostics)
}

