import Foundation

/// Client-side presence check result for a manifest entry.
public enum LocalFileStatus: Sendable, Equatable {
    /// Not on disk — must be pulled.
    case missing
    /// On disk with a matching checksum — skip.
    case presentMatching
    /// On disk but different content (stale save, different dump) — the pull
    /// plan treats this as needing transfer; the app decides overwrite policy.
    case presentDiffering
}

/// Bridges ContinuityKit to the host app's file layout. The app adapter wraps
/// FlycastPaths, GdRomLayoutChecker (multi-file game sets), BIOSRequirement,
/// the VMU directories, and SaveStateCatalog (including the Naomi stem rule).
public protocol ContinuityFileProviding: Sendable {
    /// All files of `kind` belonging to `identity`, paths relative to the
    /// documents root. Serving side.
    func enumerate(kind: FileKind, identity: GameIdentity) async throws -> [FileDescriptor]

    /// Absolute URL for a descriptor this device serves. Serving side.
    func fileURL(for descriptor: FileDescriptor) async throws -> URL

    /// Whether this device already has the descriptor's file. Receiving side.
    func localStatus(of descriptor: FileDescriptor) async -> LocalFileStatus

    /// Absolute URL where a pulled descriptor must land — same relative path
    /// as the source device, under this device's documents root.
    /// Intermediate directories are the implementation's responsibility.
    func destinationURL(for descriptor: FileDescriptor) async throws -> URL
}
