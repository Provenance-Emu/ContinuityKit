import CryptoKit
import Foundation

/// Validates the per-session bearer token on every continuity route. Unlike
/// the debug API's reserved-but-inert auth, this is enforced: no valid token,
/// no bytes.
public struct BearerTokenValidator: Sendable {
    private let expectedDigest: SHA256Digest

    public init(token: String) {
        self.expectedDigest = SHA256.hash(data: Data(token.utf8))
    }

    /// Mints a 256-bit random token, base64url-encoded.
    public static func mintToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        var generator = SystemRandomNumberGenerator()
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: .min ... .max, using: &generator)
        }
        return Data(bytes)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Accepts `Authorization: Bearer <token>`. Comparison is over SHA-256
    /// digests so timing doesn't leak prefix matches of the raw token.
    public func validate(authorizationHeader: String?) -> Bool {
        guard let authorizationHeader else { return false }
        let prefix = "Bearer "
        guard authorizationHeader.hasPrefix(prefix) else { return false }
        let presented = String(authorizationHeader.dropFirst(prefix.count))
        let presentedDigest = SHA256.hash(data: Data(presented.utf8))
        return presentedDigest == expectedDigest
    }
}
