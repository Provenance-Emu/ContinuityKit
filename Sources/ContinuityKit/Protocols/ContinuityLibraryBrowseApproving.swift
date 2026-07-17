/// Host-side hook for the first-browse consent prompt ("X wants to browse
/// your game library"). P1 offers two grants; P3 adds Ask-Per-Game.
public enum ContinuityLibraryBrowseDecision: Sendable {
    case shareEverything
    case dontShare
}

public protocol ContinuityLibraryBrowseApproving: Sendable {
    func approveLibraryBrowse(peerName: String) async -> ContinuityLibraryBrowseDecision
}
