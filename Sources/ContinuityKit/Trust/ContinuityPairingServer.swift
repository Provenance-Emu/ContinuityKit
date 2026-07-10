import Foundation

/// Host-side hook that shows the pairing prompt (peer name + 6-digit code) on
/// the serving device and resolves with the user's allow/deny.
public protocol ContinuityPairingApproving: Sendable {
    func approvePairing(peerName: String, code: String) async -> Bool
}

/// Server side of cross-user trust: pairing (one-time, code-verified,
/// user-approved) and trusted-peer auth (silent, signature over a single-use
/// nonce). On success both hand out the ACTIVE session's bearer token — the
/// same token same-user transports carry in the Handoff activity, so
/// everything downstream (manifest/mint/file) is unchanged.
///
/// Flow shape: pair/start returns immediately (the approval prompt runs in a
/// detached task) and pair/complete answers 202 while approval is pending —
/// the client polls. Codes expire after `pairingLifetime`, proofs get
/// `maxProofAttempts` tries, nonces are single-use.
public actor ContinuityPairingServer {
    public static let pairingLifetime: TimeInterval = 120
    public static let authLifetime: TimeInterval = 30
    public static let maxProofAttempts = 3
    /// In-flight pairing cap — a LAN flooder can't queue unbounded prompts.
    static let maxPendingPairings = 3

    private struct PendingPairing {
        let clientId: String
        let clientName: String
        let clientPublicKey: Data
        let code: String
        let expiresAt: Date
        var attemptsLeft: Int
        var approval: Approval = .pending

        enum Approval { case pending, approved, denied }
    }

    private struct PendingAuth {
        let peerId: String
        let nonce: Data
        let expiresAt: Date
    }

    private let identity: ContinuityPeerIdentity
    private let trustStore: any ContinuityTrustStore
    private let approver: any ContinuityPairingApproving
    /// The active handoff session's token, or nil when no session is live.
    private let sessionTokenProvider: @Sendable () async -> String?

    private var pendingPairings: [String: PendingPairing] = [:]
    private var pendingAuths: [String: PendingAuth] = [:]
    private var routesRegistered = false

    public init(
        identity: ContinuityPeerIdentity,
        trustStore: any ContinuityTrustStore,
        approver: any ContinuityPairingApproving,
        sessionTokenProvider: @escaping @Sendable () async -> String?
    ) {
        self.identity = identity
        self.trustStore = trustStore
        self.approver = approver
        self.sessionTokenProvider = sessionTokenProvider
    }

    /// Registers the pairing/auth routes. Call once at server setup; safe to
    /// call again (no-op).
    public func activate(on registrar: any ContinuityRouteRegistrar) {
        guard !routesRegistered else { return }
        routesRegistered = true

        registrar.register(method: "POST", path: ContinuityRoutes.pairStart) { [weak self] request in
            await self?.handlePairStart(request) ?? .error(status: 404, message: "unavailable")
        }
        registrar.register(method: "POST", path: ContinuityRoutes.pairComplete) { [weak self] request in
            await self?.handlePairComplete(request) ?? .error(status: 404, message: "unavailable")
        }
        registrar.register(method: "POST", path: ContinuityRoutes.authStart) { [weak self] request in
            await self?.handleAuthStart(request) ?? .error(status: 404, message: "unavailable")
        }
        registrar.register(method: "POST", path: ContinuityRoutes.authComplete) { [weak self] request in
            await self?.handleAuthComplete(request) ?? .error(status: 404, message: "unavailable")
        }
    }

    // MARK: - Pairing

    private func handlePairStart(_ request: ContinuityHTTPRequest) async -> ContinuityHTTPResponse {
        guard let body: ContinuityPairingMessages.PairStartRequest = decode(request) else {
            return .error(status: 400, message: "invalid pairing request")
        }
        prunePending()
        guard pendingPairings.count < Self.maxPendingPairings else {
            return .error(status: 429, message: "too many pairing attempts in flight")
        }

        let pairingId = UUID().uuidString
        let code = ContinuityPairingMath.makePairingCode()
        pendingPairings[pairingId] = PendingPairing(
            clientId: body.peerId,
            clientName: body.name,
            clientPublicKey: body.publicKey,
            code: code,
            expiresAt: Date().addingTimeInterval(Self.pairingLifetime),
            attemptsLeft: Self.maxProofAttempts
        )

        // Prompt off this request's lifetime — the client returns immediately
        // and polls pair/complete while the user decides. The prompt is raced
        // against the pairing lifetime: a host UI that can't present (or a
        // user who never answers) must not park the approver forever, or every
        // FUTURE pairing request would be auto-declined by the stuck prompt.
        Task { [approver] in
            let approved = await Self.withTimeout(Self.pairingLifetime) {
                await approver.approvePairing(peerName: body.name, code: code)
            } ?? false
            self.resolveApproval(pairingId: pairingId, approved: approved)
        }

        return encode(ContinuityPairingMessages.PairStartResponse(
            pairingId: pairingId,
            serverId: identity.id,
            serverName: identity.name,
            serverPublicKey: identity.publicKeyData
        ))
    }

    private func resolveApproval(pairingId: String, approved: Bool) {
        guard var pending = pendingPairings[pairingId] else { return }
        pending.approval = approved ? .approved : .denied
        pendingPairings[pairingId] = pending
    }

    private func handlePairComplete(_ request: ContinuityHTTPRequest) async -> ContinuityHTTPResponse {
        guard let body: ContinuityPairingMessages.PairCompleteRequest = decode(request) else {
            return .error(status: 400, message: "invalid pairing completion")
        }
        guard var pending = pendingPairings[body.pairingId], pending.expiresAt > Date() else {
            pendingPairings[body.pairingId] = nil
            return .error(status: 410, message: "pairing expired or unknown")
        }

        switch pending.approval {
        case .pending:
            return .error(status: 202, message: "waiting for approval on the other device")
        case .denied:
            pendingPairings[body.pairingId] = nil
            return .error(status: 403, message: "pairing was declined")
        case .approved:
            break
        }

        let transcript = ContinuityPairingMath.pairingTranscript(
            pairingId: body.pairingId,
            clientId: pending.clientId,
            serverId: identity.id,
            clientPublicKey: pending.clientPublicKey,
            serverPublicKey: identity.publicKeyData
        )
        guard ContinuityPairingMath.verifyPairingProof(body.proof, code: pending.code, transcript: transcript) else {
            pending.attemptsLeft -= 1
            if pending.attemptsLeft <= 0 {
                pendingPairings[body.pairingId] = nil
                return .error(status: 410, message: "too many bad codes — start pairing again")
            }
            pendingPairings[body.pairingId] = pending
            // 401 (retryable bad credential) vs 403 (terminal decline above).
            return .error(status: 401, message: "wrong code")
        }

        pendingPairings[body.pairingId] = nil
        await trustStore.add(TrustedPeer(
            id: pending.clientId,
            name: pending.clientName,
            publicKey: pending.clientPublicKey
        ))
        return await sessionTokenResponse()
    }

    // MARK: - Trusted-peer auth

    private func handleAuthStart(_ request: ContinuityHTTPRequest) async -> ContinuityHTTPResponse {
        guard let body: ContinuityPairingMessages.AuthStartRequest = decode(request) else {
            return .error(status: 400, message: "invalid auth request")
        }
        guard await trustStore.peer(withId: body.peerId) != nil else {
            return .error(status: 403, message: "not a paired device")
        }
        pruneAuths()

        let authId = UUID().uuidString
        let nonce = ContinuityPairingMath.makeNonce()
        pendingAuths[authId] = PendingAuth(
            peerId: body.peerId,
            nonce: nonce,
            expiresAt: Date().addingTimeInterval(Self.authLifetime)
        )
        return encode(ContinuityPairingMessages.AuthStartResponse(
            authId: authId, serverId: identity.id, nonce: nonce
        ))
    }

    private func handleAuthComplete(_ request: ContinuityHTTPRequest) async -> ContinuityHTTPResponse {
        guard let body: ContinuityPairingMessages.AuthCompleteRequest = decode(request) else {
            return .error(status: 400, message: "invalid auth completion")
        }
        // Single-use: the nonce is consumed no matter how verification goes.
        guard let pending = pendingAuths.removeValue(forKey: body.authId),
              pending.expiresAt > Date(),
              pending.peerId == body.peerId else {
            return .error(status: 410, message: "auth challenge expired or unknown")
        }
        guard let peer = await trustStore.peer(withId: body.peerId),
              ContinuityPairingMath.verifyAuth(
                signature: body.signature,
                nonce: pending.nonce,
                peerId: peer.id,
                serverId: identity.id,
                publicKey: peer.publicKey
              ) else {
            return .error(status: 403, message: "signature verification failed")
        }
        return await sessionTokenResponse()
    }

    // MARK: - Helpers

    private func sessionTokenResponse() async -> ContinuityHTTPResponse {
        guard let token = await sessionTokenProvider() else {
            return .error(status: 404, message: "no active handoff session")
        }
        return encode(ContinuityPairingMessages.SessionTokenResponse(sessionToken: token))
    }

    private func prunePending() {
        let now = Date()
        pendingPairings = pendingPairings.filter { $0.value.expiresAt > now }
    }

    private func pruneAuths() {
        let now = Date()
        pendingAuths = pendingAuths.filter { $0.value.expiresAt > now }
    }

    /// nil on timeout. The losing task isn't force-killed (an approval prompt
    /// awaiting a continuation can't be cancelled) — a late answer is simply
    /// dropped, and resolveApproval on a pruned pairingId no-ops.
    private static func withTimeout(
        _ seconds: TimeInterval,
        _ body: @escaping @Sendable () async -> Bool
    ) async -> Bool? {
        await withTaskGroup(of: Bool?.self) { group in
            group.addTask { await body() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private func decode<T: Decodable>(_ request: ContinuityHTTPRequest) -> T? {
        guard let body = request.body else { return nil }
        return try? JSONDecoder().decode(T.self, from: body)
    }

    private func encode<T: Encodable>(_ payload: T) -> ContinuityHTTPResponse {
        guard let data = try? JSONEncoder().encode(payload) else {
            return .error(status: 500, message: "encoding failed")
        }
        return .json(data)
    }
}
