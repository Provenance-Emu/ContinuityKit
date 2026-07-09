import ContinuityKit

public final class MockLibrary: LibraryQuerying, @unchecked Sendable {
    public var match: LocalGameMatch?
    public private(set) var queriedIdentities: [GameIdentity] = []

    public init(match: LocalGameMatch? = nil) {
        self.match = match
    }

    public func resolveLocalGame(_ identity: GameIdentity) async -> LocalGameMatch? {
        queriedIdentities.append(identity)
        return match
    }
}
