import DCSSCore
import Foundation
import Observation

@MainActor
@Observable
final class HostViewModel {
    var serverURL = "wss://example.com/socket"
    var connectionStatus = "idle"
    var grid: [String] = []
    var statusLine = ""
    var lastMessage = ""
    var commandInput = ""

    var debugLastEvent = "-"
    var debugReconnectAttempt = "-"
    var debugLastError = "-"

    private let settings: SettingsStore
    private let session: SessionActor

    init(
        settings: SettingsStore = UserDefaultsSettingsStore(),
        session: SessionActor = SessionActor(transport: WebSocketTransport())
    ) {
        self.settings = settings
        self.session = session
        serverURL = settings.serverURLString
    }

    func connect() async {
        settings.serverURLString = serverURL
        guard let url = URL(string: serverURL) else {
            connectionStatus = "invalid url"
            debugLastError = "Invalid URL"
            return
        }

        await session.connect(url: url)
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
        connectionStatus = String(describing: snapshot.0)
        grid = snapshot.1.grid
        statusLine = snapshot.1.statusLine
        lastMessage = snapshot.1.lastMessage
        debugLastEvent = snapshot.2.lastEventType ?? "-"
        debugReconnectAttempt = snapshot.2.reconnectAttempt.map(String.init) ?? "-"
        debugLastError = snapshot.2.lastError ?? "-"
    }
}
