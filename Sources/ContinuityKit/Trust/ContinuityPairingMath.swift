import CryptoKit
import Foundation

/// Pure crypto for the pairing + auth handshakes — kept side-effect-free so
/// every operation is unit-testable and both endpoints share one definition.
///
/// Threat model (documented, deliberate): traffic is plain HTTP on the local
/// network, same as the phase-1 session. Pairing raises the bar from
/// "anyone who can read the TXT record" to "someone the user explicitly
/// approved, proven present by the on-screen code"; it does NOT add transport
/// confidentiality. Trusted-peer auth proves possession of the paired private
/// key via a single-use server nonce (no replay).
public enum ContinuityPairingMath {
    /// 6-digit, zero-padded, uniformly random display code.
    public static func makePairingCode() -> String {
        String(format: "%06d", Int.random(in: 0...999_999))
    }

    /// Canonical transcript both sides bind the proof to — every identity
    /// field plus both public keys, so a mismatch anywhere breaks the HMAC.
    public static func pairingTranscript(
        pairingId: String,
        clientId: String,
        serverId: String,
        clientPublicKey: Data,
        serverPublicKey: Data
    ) -> Data {
        var transcript = Data("ifly-continuity-pair-v1|".utf8)
        transcript += Data("\(pairingId)|\(clientId)|\(serverId)|".utf8)
        transcript += clientPublicKey
        transcript += Data("|".utf8)
        transcript += serverPublicKey
        return transcript
    }

    /// Proof the client's user saw the code on the server's screen:
    /// HMAC-SHA256 keyed on the code digest over the transcript.
    public static func pairingProof(code: String, transcript: Data) -> Data {
        let key = SymmetricKey(data: Data(SHA256.hash(data: Data(code.utf8))))
        return Data(HMAC<SHA256>.authenticationCode(for: transcript, using: key))
    }

    /// Constant-time proof check.
    public static func verifyPairingProof(_ proof: Data, code: String, transcript: Data) -> Bool {
        let key = SymmetricKey(data: Data(SHA256.hash(data: Data(code.utf8))))
        return HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: transcript, using: key)
    }

    /// Single-use random auth nonce.
    public static func makeNonce() -> Data {
        Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
    }

    /// What a trusted peer signs to claim an active session: the nonce bound
    /// to both identities (so a signature can't be relayed to another server).
    public static func authMessage(nonce: Data, peerId: String, serverId: String) -> Data {
        var message = Data("ifly-continuity-auth-v1|".utf8)
        message += Data("\(peerId)|\(serverId)|".utf8)
        message += nonce
        return message
    }

    public static func signAuth(
        nonce: Data, peerId: String, serverId: String,
        signingKey: Curve25519.Signing.PrivateKey
    ) throws -> Data {
        try signingKey.signature(for: authMessage(nonce: nonce, peerId: peerId, serverId: serverId))
    }

    public static func verifyAuth(
        signature: Data, nonce: Data, peerId: String, serverId: String,
        publicKey: Data
    ) -> Bool {
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey) else {
            return false
        }
        return key.isValidSignature(
            signature,
            for: authMessage(nonce: nonce, peerId: peerId, serverId: serverId)
        )
    }
}
