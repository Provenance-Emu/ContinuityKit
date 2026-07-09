import ContinuityKit

public final class MockSaveStateMinter: SaveStateMinting, @unchecked Sendable {
    public var descriptor: SaveStateDescriptor?
    public var error: ContinuityError?
    public private(set) var mintCount = 0

    public init(descriptor: SaveStateDescriptor? = nil) {
        self.descriptor = descriptor
    }

    public func mintHandoffState(identity: GameIdentity) async throws -> SaveStateDescriptor {
        mintCount += 1
        if let error { throw error }
        guard let descriptor else { throw ContinuityError.noActiveSession }
        return descriptor
    }
}
