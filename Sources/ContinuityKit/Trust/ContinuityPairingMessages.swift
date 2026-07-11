import Foundation

/// Wire types for the pairing + trusted-peer auth routes. `Data` fields ride
/// as base64 strings (Codable's JSON default) — same convention both ends.
public enum ContinuityPairingMessages {
    public struct PairStartRequest: Codable, Sendable {
        public var peerId: String
        public var name: String
        public var publicKey: Data

        public init(peerId: String, name: String, publicKey: Data) {
            self.peerId = peerId
            self.name = name
            self.publicKey = publicKey
        }
    }

    public struct PairStartResponse: Codable, Sendable {
        public var pairingId: String
        public var serverId: String
        public var serverName: String
        public var serverPublicKey: Data

        public init(pairingId: String, serverId: String, serverName: String, serverPublicKey: Data) {
            self.pairingId = pairingId
            self.serverId = serverId
            self.serverName = serverName
            self.serverPublicKey = serverPublicKey
        }
    }

    public struct PairCompleteRequest: Codable, Sendable {
        public var pairingId: String
        public var proof: Data

        public init(pairingId: String, proof: Data) {
            self.pairingId = pairingId
            self.proof = proof
        }
    }

    public struct AuthStartRequest: Codable, Sendable {
        public var peerId: String

        public init(peerId: String) {
            self.peerId = peerId
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

    public struct ContinueStartRequest: Codable, Sendable {
        public var peerId: String
        public var name: String
        /// Carried so an "Always Allow" answer can add the peer to the trust
        /// store (trust-on-first-use) without a separate pairing round.
        public var publicKey: Data

        public init(peerId: String, name: String, publicKey: Data) {
            self.peerId = peerId
            self.name = name
            self.publicKey = publicKey
        }
    }

    public struct ContinueStartResponse: Codable, Sendable {
        public var requestId: String
        public var serverId: String
        public var serverName: String

        public init(requestId: String, serverId: String, serverName: String) {
            self.requestId = requestId
            self.serverId = serverId
            self.serverName = serverName
        }
    }

    public struct ContinuePollRequest: Codable, Sendable {
        public var requestId: String

        public init(requestId: String) {
            self.requestId = requestId
        }
    }

    /// Terminal success payload for pair/complete, auth/complete, and
    /// continue/poll: the active session's bearer token.
    public struct SessionTokenResponse: Codable, Sendable {
        public var sessionToken: String

        public init(sessionToken: String) {
            self.sessionToken = sessionToken
        }
    }
}
