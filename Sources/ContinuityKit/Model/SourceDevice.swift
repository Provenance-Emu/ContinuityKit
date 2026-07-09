public struct SourceDevice: Codable, Hashable, Sendable {
    public var name: String
    /// e.g. "iOS", "tvOS", "macOS"
    public var platform: String
    public var appVersion: String

    public init(name: String, platform: String, appVersion: String) {
        self.name = name
        self.platform = platform
        self.appVersion = appVersion
    }
}
