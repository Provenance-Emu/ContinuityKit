import Foundation

/// Wire types for the library browse-auth routes. Same shape family as
/// ContinuityPairingMessages (Data rides as base64 in JSON).
public enum ContinuityLibraryMessages {
    /// Carries name + publicKey up front so an undecided host can prompt
    /// ("X wants to browse…") and, on Share Everything, TOFU-trust the peer
    /// without another round trip. `icloudHash` (additive, optional) is the
    /// sender's ContinuityICloudHash — when it matches the host's own, the
    /// host may skip the consent prompt (same-iCloud auto-trust).
    public struct AuthStartRequest: Codable, Sendable {
        public var peerId: String
        public var name: String
        public var publicKey: Data
        public var icloudHash: String?

        public init(peerId: String, name: String, publicKey: Data, icloudHash: String? = nil) {
            self.peerId = peerId
            self.name = name
            self.publicKey = publicKey
            self.icloudHash = icloudHash
        }
    }

    public struct AuthStartResponse: Codable, Sendable {
        public var authId: String
        public var serverId: String
        public var nonce: Data

        public init(authId: String, serverId: String, nonce: Data) {
            self.authId = authId
            self.serverId = serverId
            self.nonce = nonce
        }
    }

    public struct AuthCompleteRequest: Codable, Sendable {
        public var authId: String
        public var peerId: String
        public var signature: Data

        public init(authId: String, peerId: String, signature: Data) {
            self.authId = authId
            self.peerId = peerId
            self.signature = signature
        }
    }

    /// Body of POST libraryPull: the manifest `Game.id` the browser wants.
    public struct PullRequest: Codable, Sendable {
        public var gameId: String

        public init(gameId: String) {
            self.gameId = gameId
        }
    }

    /// Terminal success payload: a LIBRARY-scoped bearer token. Distinct from
    /// SessionTokenResponse on purpose — the two token families must never mix.
    public struct LibraryTokenResponse: Codable, Sendable {
        public var libraryToken: String

        public init(libraryToken: String) {
            self.libraryToken = libraryToken
        }
    }
}
