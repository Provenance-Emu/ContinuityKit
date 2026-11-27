import CryptoKit
import Foundation

/// The peer identity carried by the Continuity v2 authorization handshake.
public struct ContinuityV2AuthPeer: Codable, Equatable, Sendable {
    public let pid: String
    public let app: String
    public let name: String
    public let publicKey: Data

    public init(pid: String, app: String, name: String, publicKey: Data) {
        self.pid = pid
        self.app = app
        self.name = name
        self.publicKey = publicKey
    }

    /// The lowercase SHA-256 identifier of a raw Ed25519 public key.
    public static func peerID(for publicKey: Data) -> String {
        SHA256.hash(data: publicKey).map { String(format: "%02x", $0) }.joined()
    }

    fileprivate var hasValidIdentity: Bool {
        publicKey.count == 32 &&
            pid == Self.peerID(for: publicKey) &&
            ["provenance", "ifly", "icube"].contains(app)
    }
}

/// The exact bytes signed by a Continuity v2 client for one authorization exchange.
public struct ContinuityV2AuthTranscript: Equatable, Sendable {
    public enum ValidationError: Error, Equatable {
        case invalidIdentity
        case invalidChallenge
        case invalidList
        case fieldTooLong
    }

    public let bytes: Data
    private let clientKey: Data

    /// Lists must already be in wire order. Unknown labels remain bound to the signature.
    public init(
        authID: String,
        client: ContinuityV2AuthPeer,
        server: ContinuityV2AuthPeer,
        nonce: Data,
        scopes: [String],
        saveFormats: [String] = []
    ) throws {
        guard client.hasValidIdentity, server.hasValidIdentity else { throw ValidationError.invalidIdentity }
        guard !authID.isEmpty, nonce.count == 32 else { throw ValidationError.invalidChallenge }
        guard Self.isCanonical(scopes), Self.isCanonical(saveFormats) else { throw ValidationError.invalidList }

        let fields = [
            Data(authID.utf8),
            Data(client.pid.utf8), Data(client.app.utf8), client.publicKey,
            Data(server.pid.utf8), Data(server.app.utf8), server.publicKey,
            nonce,
            Data(scopes.joined(separator: ",").utf8),
            Data(saveFormats.joined(separator: ",").utf8)
        ]
        var transcript = Data("pvcontinuity-auth-v2|".utf8)
        for field in fields {
            guard let count = UInt32(exactly: field.count) else { throw ValidationError.fieldTooLong }
            withUnsafeBytes(of: count.bigEndian) { transcript.append(contentsOf: $0) }
            transcript.append(field)
        }
        bytes = transcript
        clientKey = client.publicKey
    }

    /// Verifies client key possession. Challenge lifetime, replay and grants are checked by the host.
    public func verifies(clientSignature: Data) -> Bool {
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: clientKey) else { return false }
        return key.isValidSignature(clientSignature, for: bytes)
    }

    private static func isCanonical(_ labels: [String]) -> Bool {
        labels == labels.sorted() && Set(labels).count == labels.count && labels.allSatisfy { label in
            !label.isEmpty && label.utf8.allSatisfy { (0x21...0x7e).contains($0) && $0 != 0x2c }
        }
    }
}
