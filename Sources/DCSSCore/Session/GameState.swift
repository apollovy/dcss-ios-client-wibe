import Foundation

public struct GameState: Equatable, Sendable {
    public var grid: [String]
    public var statusLine: String
    public var lastMessage: String
    /// Raw JSON lines for each element of the `msgs` array from the server (when present).
    public var msgsJsonLog: [String]

    public init(
        grid: [String] = [],
        statusLine: String = "",
        lastMessage: String = "",
        msgsJsonLog: [String] = []
    ) {
        self.grid = grid
        self.statusLine = statusLine
        self.lastMessage = lastMessage
        self.msgsJsonLog = msgsJsonLog
    }
}
