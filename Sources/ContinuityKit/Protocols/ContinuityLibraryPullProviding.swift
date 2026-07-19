import Foundation

/// Host app's seam feeding the METERED library-pull routes: a full transfer
/// manifest for one library game (game files + BIOS + per-game VMU + save
/// states, built the same way a session manifest is), and absolute-URL
/// resolution for descriptors of previously granted pull manifests.
public protocol ContinuityLibraryPullProviding: Sendable {
    /// nil = no library game matches `gameId` (manifest `Game.id`).
    func pullManifest(forGameId gameId: String) async throws -> ContinuityManifest?
    /// Absolute URL for a relative path this host serves; nil = unknown.
    func fileURL(forRelativePath relativePath: String) async throws -> URL?
}
