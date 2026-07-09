import Foundation

/// A device the user explicitly paired with — the unit of cross-user trust.
/// Same-user devices keep the phase-1 model (token in the Handoff activity /
/// TXT record); OTHER people's devices must pair once, after which their
/// Ed25519 public key authenticates every later session without a prompt.
public struct TrustedPeer: Codable, Hashable, Sendable, Identifiable {
    /// Stable peer-chosen identifier (one per app install).
    public var id: String
    public var name: String
    /// Raw-representation Ed25519 verifying key.
    public var publicKey: Data
    public var addedAt: Date

    public init(id: String, name: String, publicKey: Data, addedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.publicKey = publicKey
        self.addedAt = addedAt
    }
}
