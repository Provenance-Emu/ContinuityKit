/// Host-side hook for the first-browse consent prompt ("X wants to browse
/// your game library").
public enum ContinuityLibraryBrowseDecision: Sendable {
    case shareEverything
    /// Browse freely, but every pull raises an owner-side approval prompt.
    case askPerGame
    case dontShare
}

public protocol ContinuityLibraryBrowseApproving: Sendable {
    func approveLibraryBrowse(peerName: String) async -> ContinuityLibraryBrowseDecision
}
