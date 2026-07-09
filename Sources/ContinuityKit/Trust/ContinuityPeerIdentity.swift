import CryptoKit
import Foundation

/// This device's long-term pairing identity: a stable id, a display name, and
/// an Ed25519 signing key. The kit never persists the private key — the host
/// passes `privateKeyData` back in (from Keychain or a protected file) so key
/// custody stays the app's decision.
public struct ContinuityPeerIdentity: Sendable {
    public let id: String
    public let name: String
    public let signingKey: Curve25519.Signing.PrivateKey

    public var publicKeyData: Data { signingKey.publicKey.rawRepresentation }
    public var privateKeyData: Data { signingKey.rawRepresentation }

    /// Fresh identity (first launch).
    public init(id: String = UUID().uuidString, name: String) {
        self.id = id
        self.name = name
        self.signingKey = Curve25519.Signing.PrivateKey()
    }

    /// Restored identity (host-persisted key material).
    public init(id: String, name: String, privateKeyData: Data) throws {
        self.id = id
        self.name = name
        self.signingKey = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKeyData)
    }

    public func asTrustedPeer() -> TrustedPeer {
        TrustedPeer(id: id, name: name, publicKey: publicKeyData)
    }
}
