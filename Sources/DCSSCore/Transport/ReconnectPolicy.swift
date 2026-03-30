import Foundation

public struct ReconnectPolicy: Sendable {
    public let maxAttempts: Int
    public let baseDelay: TimeInterval

    public init(maxAttempts: Int = 5, baseDelay: TimeInterval = 1.0) {
        self.maxAttempts = maxAttempts
        self.baseDelay = baseDelay
    }

    public func delay(for attempt: Int) -> TimeInterval {
        min(pow(2, Double(attempt)) * baseDelay, 20.0)
    }
}
