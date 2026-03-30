import Foundation

public struct GameState: Equatable, Sendable {
    public var grid: [String]
    public var statusLine: String
    public var lastMessage: String

    public init(grid: [String] = [], statusLine: String = "", lastMessage: String = "") {
        self.grid = grid
        self.statusLine = statusLine
        self.lastMessage = lastMessage
    }
}
