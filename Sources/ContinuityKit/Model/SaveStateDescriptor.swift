import Foundation

/// Describes the minted handoff save state. `stem` is the flycast-derived
/// filename stem (which for Naomi/arcade zips can diverge from the game path
/// basename) — the receiving device must use this stem verbatim, never derive
/// it from the game path.
public struct SaveStateDescriptor: Codable, Hashable, Sendable {
    public var slot: Int
    public var stem: String
    public var relativePath: String
    public var sha256: String
    public var size: Int64
    public var screenshotAvailable: Bool

    public init(
        slot: Int,
        stem: String,
        relativePath: String,
        sha256: String,
        size: Int64,
        screenshotAvailable: Bool = false
    ) {
        self.slot = slot
        self.stem = stem
        self.relativePath = relativePath
        self.sha256 = sha256
        self.size = size
        self.screenshotAvailable = screenshotAvailable
    }

    /// The save state as a transferable file entry.
    public var fileDescriptor: FileDescriptor {
        FileDescriptor(
            kind: .saveState,
            relativePath: relativePath,
            sha256: sha256,
            size: size,
            required: true
        )
    }
}
