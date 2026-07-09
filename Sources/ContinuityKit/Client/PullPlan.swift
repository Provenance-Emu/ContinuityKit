import Foundation

/// What a pull will actually transfer, computed by diffing a manifest against
/// local files. Drives the progress UI and the optional-extras prompt.
public struct PullPlan: Sendable, Equatable {
    /// Files to download, already sorted: small/critical kinds first (save
    /// state, VMU, BIOS) then game files — a dying server leaves the most
    /// usable partial payload.
    public var needed: [FileDescriptor]
    /// Manifest entries already on this device with matching checksums.
    public var alreadyPresent: [FileDescriptor]
    /// Opt-in groups the user can add (texture packs, …).
    public var optionalExtras: [OptionalExtra]

    public init(needed: [FileDescriptor], alreadyPresent: [FileDescriptor], optionalExtras: [OptionalExtra]) {
        self.needed = needed
        self.alreadyPresent = alreadyPresent
        self.optionalExtras = optionalExtras
    }

    public var totalBytesNeeded: Int64 {
        needed.reduce(0) { $0 + $1.size }
    }

    /// Nothing to transfer — the game (and state, if any) is already local.
    public var isNoOp: Bool { needed.isEmpty }
}
