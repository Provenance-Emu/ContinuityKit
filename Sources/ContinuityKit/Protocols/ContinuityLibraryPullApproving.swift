/// Owner's answer to one pull request from an Ask-Per-Game peer.
public enum ContinuityLibraryPullDecision: Sendable {
    /// This pull only — the next pull prompts again.
    case allow
    /// Upgrade the peer's grant to Everything; no further prompts.
    case alwaysForDevice
    /// This pull only — the peer stays Ask-Per-Game.
    case deny
}

/// Host-side hook for the Ask-Per-Game pull prompt ("X wants to copy
/// <game>"). Same await-the-UI shape as ContinuityLibraryBrowseApproving;
/// the server times out to `.deny` on its own clock.
public protocol ContinuityLibraryPullApproving: Sendable {
    func approveLibraryPull(peerName: String, gameTitle: String) async -> ContinuityLibraryPullDecision
}
