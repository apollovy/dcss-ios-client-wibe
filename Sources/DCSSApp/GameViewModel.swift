import DCSSCore
import DCSSCoreFFI
import Foundation
import Observation

@MainActor
@Observable
final class GameViewModel {
    var serverURL = "wss://example.com/socket"
    /// Текущее состояние сессии (для опроса снимка из Rust).
    private(set) var connectionState: DCSSConnectionState = .idle
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
    /// One JSON object per line from `msgs` envelopes (Rust core).
    var msgsJsonLog: [String] = []

    private let settings: SettingsStore
    private nonisolated let session: any SessionClient

    init(
        settings: SettingsStore = UserDefaultsSettingsStore(),
        session: (any SessionClient)? = nil
    ) {
        self.settings = settings
        self.session = session ?? RustSessionClient.makeOrNil() ?? SessionActor(transport: WebSocketTransport())
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

        await session.connect(url: url, clientVersion: nil)
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
        connectionState = snapshot.0
        connectionStatus = String(describing: snapshot.0)

        let game = snapshot.1
        grid = game.grid
        statusLine = game.statusLine
        lastMessage = game.lastMessage
        msgsJsonLog = game.msgsJsonLog

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

    /// Rust обновляет состояние в фоне; без периодического снимка UI не видит новые `msgs` / grid.
    func runSnapshotPollLoop() async {
        while !Task.isCancelled {
            await syncFromSession()
            let nanos: UInt64 = switch connectionState {
            case .connected, .connecting, .reconnecting:
                250_000_000 // 250 ms
            case .idle, .failed:
                1_000_000_000 // 1 s
            }
            try? await Task.sleep(nanoseconds: nanos)
        }
    }
}
