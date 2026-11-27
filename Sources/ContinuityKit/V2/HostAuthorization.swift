import CryptoKit
import Foundation

/// In-memory authorization state for one Continuity v2 listener.
public actor ContinuityV2HostAuthorization {
    public enum Policy: Sendable {
        case deny
        case ask
        case grant(Set<String>)
    }

    public enum Failure: Error, Equatable {
        case challengeExpired
        case denied
        case capacityReached
    }

    public struct Challenge: Codable, Sendable {
        public let authId: String
        public let server: ContinuityV2AuthPeer
        public let nonce: Data
        public let expiresAt: Date
    }

    public struct Approval: Sendable {
        public let authId: String
        public let client: ContinuityV2AuthPeer
        public let scopes: [String]
    }

    public struct Token: Codable, Sendable {
        public let token: String
        public let scopes: [String]
        public let expiresAt: Date
    }

    public struct Grant: Sendable {
        public let client: ContinuityV2AuthPeer
        public let scopes: Set<String>
        public let saveFormats: [String]
    }

    public enum Completion: Sendable {
        case needsApproval(Approval)
        case pending
        case authorized(Token)
    }

    private enum Decision {
        case awaitingSignature
        case awaitingApproval(Data)
        case approved(Data, Set<String>)
    }

    private struct Exchange {
        let client: ContinuityV2AuthPeer
        let source: String
        let transcript: ContinuityV2AuthTranscript
        let requested: Set<String>
        let saveFormats: [String]
        let expiresAt: Date
        var decision: Decision = .awaitingSignature
    }

    private struct IssuedGrant {
        let grant: Grant
        let expiresAt: Date
    }

    public static let tokenLifetime: TimeInterval = 3600
    private static let supportedScopes: Set<String> = ["browse", "copy", "saves", "continue"]

    private let server: ContinuityV2AuthPeer
    private let policy: @Sendable (ContinuityV2AuthPeer) -> Policy
    private let now: @Sendable () -> Date
    private var exchanges: [String: Exchange] = [:]
    private var grants: [SHA256Digest: IssuedGrant] = [:]

    /// Policy must read current trust and sharing settings on every invocation.
    public init(
        server: ContinuityV2AuthPeer,
        policy: @escaping @Sendable (ContinuityV2AuthPeer) -> Policy,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.server = server
        self.policy = policy
        self.now = now
    }

    /// Source is the transport-observed, normalized remote IP address without its port.
    public func start(
        source: String,
        client: ContinuityV2AuthPeer,
        scopes: [String],
        saveFormats: [String] = []
    ) throws -> Challenge {
        let time = now()
        prune(at: time)
        let sourceCount = exchanges.values.filter { $0.source == source }.count
        guard exchanges.count < 32, sourceCount < 4 else { throw Failure.capacityReached }
        let id = UUID().uuidString.lowercased()
        let nonce = ContinuityPairingMath.makeNonce()
        let transcript = try ContinuityV2AuthTranscript(
            authID: id, client: client, server: server, nonce: nonce, scopes: scopes, saveFormats: saveFormats
        )
        let expiresAt = time.addingTimeInterval(120)
        exchanges[id] = Exchange(
            client: client, source: source, transcript: transcript, requested: Self.supportedScopes.intersection(scopes),
            saveFormats: saveFormats, expiresAt: expiresAt
        )
        return Challenge(authId: id, server: server, nonce: nonce, expiresAt: expiresAt)
    }

    public func complete(authId: String, signature: Data) throws -> Completion {
        let time = now()
        prune(at: time)
        guard var exchange = exchanges[authId] else { throw Failure.challengeExpired }

        switch exchange.decision {
        case .awaitingSignature:
            guard exchange.transcript.verifies(clientSignature: signature) else { throw Failure.denied }
            switch policy(exchange.client) {
            case .deny:
                exchanges[authId] = nil
                throw Failure.denied
            case .ask:
                guard !exchange.requested.isEmpty else {
                    exchanges[authId] = nil
                    throw Failure.denied
                }
                exchange.decision = .awaitingApproval(signature)
                exchanges[authId] = exchange
                return .needsApproval(Approval(authId: authId, client: exchange.client, scopes: exchange.requested.sorted()))
            case .grant(let allowed):
                return try issue(authId: authId, exchange: exchange, allowed: allowed, at: time)
            }
        case .awaitingApproval(let accepted):
            guard signature == accepted else { throw Failure.denied }
            return .pending
        case .approved(let accepted, let allowed):
            guard signature == accepted else { throw Failure.denied }
            switch policy(exchange.client) {
            case .deny:
                exchanges[authId] = nil
                throw Failure.denied
            case .ask:
                return try issue(authId: authId, exchange: exchange, allowed: allowed, at: time)
            case .grant(let current):
                return try issue(authId: authId, exchange: exchange, allowed: allowed.intersection(current), at: time)
            }
        }
    }

    /// Resolves a verified prompt. An empty grant records denial until expiry or collection.
    @discardableResult
    public func resolveApproval(authId: String, allowing scopes: Set<String>) -> Bool {
        prune(at: now())
        guard var exchange = exchanges[authId], case .awaitingApproval(let signature) = exchange.decision else { return false }
        exchange.decision = .approved(signature, scopes)
        exchanges[authId] = exchange
        return true
    }

    /// Checks a scoped bearer grant against live policy. The same peer may hold separate app grants.
    public func authorize(token: String, requiring scope: String) -> Grant? {
        prune(at: now())
        guard let issued = grants[SHA256.hash(data: Data(token.utf8))] else { return nil }
        let grant = issued.grant
        let effective: Set<String>
        switch policy(grant.client) {
        case .deny: return nil
        case .ask: effective = grant.scopes
        case .grant(let current): effective = current.intersection(grant.scopes)
        }
        guard effective.contains(scope) else { return nil }
        return Grant(client: grant.client, scopes: effective, saveFormats: grant.saveFormats)
    }

    /// Revokes all grants and exchanges for this signing identity across its apps.
    public func revoke(peerID: String) {
        revoke(peerIDs: [peerID])
    }

    /// Revokes every signing identity the host has associated with a device.
    public func revoke(peerIDs: Set<String>) {
        exchanges = exchanges.filter { !peerIDs.contains($0.value.client.pid) }
        grants = grants.filter { !peerIDs.contains($0.value.grant.client.pid) }
    }

    private func prune(at time: Date) {
        exchanges = exchanges.filter { $0.value.expiresAt > time }
        grants = grants.filter { $0.value.expiresAt > time }
    }

    private func issue(authId: String, exchange: Exchange, allowed: Set<String>, at time: Date) throws -> Completion {
        let scopes = exchange.requested.intersection(allowed)
        guard !scopes.isEmpty else {
            exchanges[authId] = nil
            throw Failure.denied
        }
        guard grants.count < 16 else { throw Failure.capacityReached }
        let token = BearerTokenValidator.mintToken()
        let expiresAt = time.addingTimeInterval(Self.tokenLifetime)
        let grant = Grant(client: exchange.client, scopes: scopes, saveFormats: exchange.saveFormats)
        grants[SHA256.hash(data: Data(token.utf8))] = IssuedGrant(grant: grant, expiresAt: expiresAt)
        exchanges[authId] = nil
        return .authorized(Token(token: token, scopes: scopes.sorted(), expiresAt: expiresAt))
    }
}
