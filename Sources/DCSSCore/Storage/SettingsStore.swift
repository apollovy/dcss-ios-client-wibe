import Foundation

public protocol SettingsStore: AnyObject {
    var serverURLString: String { get set }
    var fontScale: Double { get set }
}

public final class UserDefaultsSettingsStore: SettingsStore, @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var serverURLString: String {
        get { defaults.string(forKey: "serverURLString") ?? "wss://example.com/socket" }
        set { defaults.set(newValue, forKey: "serverURLString") }
    }

    public var fontScale: Double {
        get {
            let value = defaults.double(forKey: "fontScale")
            return value == 0 ? 1.0 : value
        }
        set { defaults.set(newValue, forKey: "fontScale") }
    }
}
