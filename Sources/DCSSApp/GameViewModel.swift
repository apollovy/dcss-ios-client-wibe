import DCSSCore
import Foundation
import Observation

@MainActor
@Observable
final class GameViewModel {
    var serverURL = "wss://example.com/socket"
    var connectionStatus = "idle"
    var grid: [String] = []
    var statusLine = ""
    var lastMessage = ""
    var commandInput = ""
    var fontScale = 1.0

    var debugLastEvent = "-"
    var debugReconnectAttempt = "-"
    var debugLastError = "-"
    var debugLastConnectedAt = "-"

    private let settings: SettingsStore
    private let session: SessionActor

    init(settings: SettingsStore = UserDefaultsSettingsStore(), session: SessionActor = SessionActor(transport: WebSocketTransport())) {
        self.settings = settings
        self.session = session
        self.serverURL = settings.serverURLString
        self.fontScale = settings.fontScale
    }

    func connect() async {
        settings.serverURLString = serverURL
        guard let url = URL(string: serverURL) else {
            connectionStatus = "invalid url"
            debugLastError = "Invalid URL"
            return
        }

        await session.connect(url: url)
        await syncFromSession()
    }

    func disconnect() async {
        await session.disconnect()
        await syncFromSession()
    }

    func sendCommand() async {
        let command = commandInput.trimmingCharacters(in: .whitespacesAndNewlines)
        commandInput = ""
        await session.sendInput(command)
        await syncFromSession()
    }

    func heartbeat() async {
        await session.sendHeartbeat()
        await syncFromSession()
    }

    func appDidEnterBackground() async {
        await session.appDidEnterBackground()
        await syncFromSession()
    }

    func appWillEnterForeground() async {
        await session.appWillEnterForeground()
        await syncFromSession()
    }

    func saveSettings() {
        settings.serverURLString = serverURL
        settings.fontScale = fontScale
    }

    func syncFromSession() async {
        let snapshot = await session.stateSnapshot()
        connectionStatus = String(describing: snapshot.0)

        let game = snapshot.1
        grid = game.grid
        statusLine = game.statusLine
        lastMessage = game.lastMessage

        let diagnostics = snapshot.2
        debugLastEvent = diagnostics.lastEventType ?? "-"
        debugReconnectAttempt = diagnostics.reconnectAttempt.map(String.init) ?? "-"
        debugLastError = diagnostics.lastError ?? "-"
        if let date = diagnostics.lastConnectedAt {
            let formatter = ISO8601DateFormatter()
            debugLastConnectedAt = formatter.string(from: date)
        } else {
            debugLastConnectedAt = "-"
        }
    }
}
