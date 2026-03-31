import DCSSCore
import DCSSCoreFFI
import Foundation
import Observation

@MainActor
@Observable
final class HostViewModel {
    var serverURL = "wss://example.com/socket"
    private(set) var connectionState: DCSSConnectionState = .idle
    var connectionStatus = "idle"
    var grid: [String] = []
    var statusLine = ""
    var lastMessage = ""
    var msgsJsonLog: [String] = []
    var commandInput = ""

    var debugLastEvent = "-"
    var debugReconnectAttempt = "-"
    var debugLastError = "-"

    private let settings: SettingsStore
    private nonisolated let session: any SessionClient

    init(
        settings: SettingsStore = UserDefaultsSettingsStore(),
        session: (any SessionClient)? = nil
    ) {
        self.settings = settings
        self.session = session ?? RustSessionClient.makeOrNil() ?? SessionActor(transport: WebSocketTransport())
        serverURL = settings.serverURLString
    }

    func connect() async {
        settings.serverURLString = serverURL
        guard let url = URL(string: serverURL) else {
            connectionStatus = "invalid url"
            debugLastError = "Invalid URL"
            return
        }

        await session.connect(url: url, clientVersion: nil)
        await refresh()
    }

    func disconnect() async {
        await session.disconnect()
        await refresh()
    }

    func sendCommand() async {
        let command = commandInput.trimmingCharacters(in: .whitespacesAndNewlines)
        commandInput = ""
        await session.sendInput(command)
        await refresh()
    }

    func sendHeartbeat() async {
        await session.sendHeartbeat()
        await refresh()
    }

    func appDidEnterBackground() async {
        await session.appDidEnterBackground()
        await refresh()
    }

    func appWillEnterForeground() async {
        await session.appWillEnterForeground()
        await refresh()
    }

    func refresh() async {
        let snapshot = await session.stateSnapshot()
        connectionState = snapshot.0
        connectionStatus = String(describing: snapshot.0)
        grid = snapshot.1.grid
        statusLine = snapshot.1.statusLine
        lastMessage = snapshot.1.lastMessage
        msgsJsonLog = snapshot.1.msgsJsonLog
        debugLastEvent = snapshot.2.lastEventType ?? "-"
        debugReconnectAttempt = snapshot.2.reconnectAttempt.map(String.init) ?? "-"
        debugLastError = snapshot.2.lastError ?? "-"
    }

    func runSnapshotPollLoop() async {
        while !Task.isCancelled {
            await refresh()
            let nanos: UInt64 = switch connectionState {
            case .connected, .connecting, .reconnecting:
                250_000_000
            case .idle, .failed:
                1_000_000_000
            }
            try? await Task.sleep(nanoseconds: nanos)
        }
    }
}
