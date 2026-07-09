/// How a local library entry was matched to a remote identity, strongest
/// first.
public enum IdentityMatchKey: String, Sendable, Codable {
    case flycastGameId
    case md5Hash
    case serial
}

/// A game already present on the receiving device.
public struct LocalGameMatch: Sendable, Equatable {
    public var matchedBy: IdentityMatchKey
    /// Path of the local game file, relative to the documents root.
    public var gameRelativePath: String
    /// Whether at least one local save state exists for this game (any slot) —
    /// feeds the fallback ladder's boot-with-latest-local-state rung.
    public var hasLocalSaveState: Bool

    public init(matchedBy: IdentityMatchKey, gameRelativePath: String, hasLocalSaveState: Bool) {
        self.matchedBy = matchedBy
        self.gameRelativePath = gameRelativePath
        self.hasLocalSaveState = hasLocalSaveState
    }
}

/// Resolves a remote game identity against the local library using the
/// flycastGameId → md5Hash → serial ladder. App adapter queries SwiftData
/// GameEntry.
public protocol LibraryQuerying: Sendable {
    func resolveLocalGame(_ identity: GameIdentity) async -> LocalGameMatch?
}
