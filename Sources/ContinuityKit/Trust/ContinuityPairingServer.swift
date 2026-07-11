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

    private struct PendingContinue {
        let peerId: String
        let peerName: String
        let peerPublicKey: Data
        let expiresAt: Date
        var decision: Decision = .pending

        enum Decision { case pending, allowOnce, allowAlways, denied }
    }

    private let identity: ContinuityPeerIdentity
    private let trustStore: any ContinuityTrustStore
    private let approver: any ContinuityPairingApproving
    /// Answers code-less continue requests. nil = the feature is off and
    /// continue/start responds 404 (older hosts behave identically because the
    /// route doesn't exist — clients treat both as "fall back to pairing").
    private let continueApprover: (any ContinuityContinueApproving)?
    /// The active handoff session's token, or nil when no session is live.
    private let sessionTokenProvider: @Sendable () async -> String?
    /// Consulted once per token handout (pair/complete, auth/complete,
    /// continue/poll success). Returning false answers 429 — the host's seam
    /// for metering pulls (free-tier allowance). The default never limits.
    private let grantPolicy: @Sendable () async -> Bool

    private var pendingPairings: [String: PendingPairing] = [:]
    private var pendingAuths: [String: PendingAuth] = [:]
    private var pendingContinues: [String: PendingContinue] = [:]
    private var routesRegistered = false

    public init(
        identity: ContinuityPeerIdentity,
        trustStore: any ContinuityTrustStore,
        approver: any ContinuityPairingApproving,
        continueApprover: (any ContinuityContinueApproving)? = nil,
        sessionTokenProvider: @escaping @Sendable () async -> String?,
        grantPolicy: @escaping @Sendable () async -> Bool = { true }
    ) {
        self.identity = identity
        self.trustStore = trustStore
        self.approver = approver
        self.continueApprover = continueApprover
        self.sessionTokenProvider = sessionTokenProvider
        self.grantPolicy = grantPolicy
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
        if continueApprover != nil {
            registrar.register(method: "POST", path: ContinuityRoutes.continueStart) { [weak self] request in
                await self?.handleContinueStart(request) ?? .error(status: 404, message: "unavailable")
            }
            registrar.register(method: "POST", path: ContinuityRoutes.continuePoll) { [weak self] request in
                await self?.handleContinuePoll(request) ?? .error(status: 404, message: "unavailable")
            }
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

    // MARK: - Code-less continue requests

    private func handleContinueStart(_ request: ContinuityHTTPRequest) async -> ContinuityHTTPResponse {
        guard let continueApprover else {
            return .error(status: 404, message: "unavailable")
        }
        guard let body: ContinuityPairingMessages.ContinueStartRequest = decode(request) else {
            return .error(status: 400, message: "invalid continue request")
        }
        pruneContinues()
        guard pendingContinues.count < Self.maxPendingPairings else {
            return .error(status: 429, message: "too many continue requests in flight")
        }

        let requestId = UUID().uuidString
        pendingContinues[requestId] = PendingContinue(
            peerId: body.peerId,
            peerName: body.name,
            peerPublicKey: body.publicKey,
            expiresAt: Date().addingTimeInterval(Self.pairingLifetime)
        )

        // Same shape as pairing: the prompt runs detached and is raced against
        // the request lifetime so a never-answered alert can't wedge the seam.
        Task {
            let decision = await Self.withTimeout(Self.pairingLifetime) {
                await continueApprover.approveContinue(peerName: body.name)
            } ?? ContinuityContinueDecision.deny
            self.resolveContinue(requestId: requestId, decision: decision)
        }

        return encode(ContinuityPairingMessages.ContinueStartResponse(
            requestId: requestId,
            serverId: identity.id,
            serverName: identity.name
        ))
    }

    private func resolveContinue(requestId: String, decision: ContinuityContinueDecision) {
        guard var pending = pendingContinues[requestId] else { return }
        switch decision {
        case .allowOnce: pending.decision = .allowOnce
        case .allowAlways: pending.decision = .allowAlways
        case .deny: pending.decision = .denied
        }
        pendingContinues[requestId] = pending
    }

    private func handleContinuePoll(_ request: ContinuityHTTPRequest) async -> ContinuityHTTPResponse {
        guard let body: ContinuityPairingMessages.ContinuePollRequest = decode(request) else {
            return .error(status: 400, message: "invalid continue poll")
        }
        guard let pending = pendingContinues[body.requestId], pending.expiresAt > Date() else {
            pendingContinues[body.requestId] = nil
            return .error(status: 410, message: "continue request expired or unknown")
        }

        switch pending.decision {
        case .pending:
            return .error(status: 202, message: "waiting for approval on the other device")
        case .denied:
            pendingContinues[body.requestId] = nil
            return .error(status: 403, message: "the other device declined")
        case .allowOnce, .allowAlways:
            break
        }

        pendingContinues[body.requestId] = nil
        if pending.decision == .allowAlways {
            await trustStore.add(TrustedPeer(
                id: pending.peerId,
                name: pending.peerName,
                publicKey: pending.peerPublicKey
            ))
        }
        return await sessionTokenResponse()
    }

    // MARK: - Helpers

    private func sessionTokenResponse() async -> ContinuityHTTPResponse {
        guard let token = await sessionTokenProvider() else {
            return .error(status: 404, message: "no active handoff session")
        }
        // The host's metering seam — every token handout (pairing, silent
        // auth, continue) is one accountable "pull".
        guard await grantPolicy() else {
            return .error(status: 429, message: "the other device's free daily pulls are used up")
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

    private func pruneContinues() {
        let now = Date()
        pendingContinues = pendingContinues.filter { $0.value.expiresAt > now }
    }

    /// nil on timeout. The losing task isn't force-killed (an approval prompt
    /// awaiting a continuation can't be cancelled) — a late answer is simply
    /// dropped, and resolveApproval on a pruned pairingId no-ops.
    private static func withTimeout<T: Sendable>(
        _ seconds: TimeInterval,
        _ body: @escaping @Sendable () async -> T
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
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
