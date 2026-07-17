import Foundation

/// Serves the Nearby Libraries browse surface: signed-nonce browse auth with
/// per-peer grants, then manifest + art routes guarded by LIBRARY bearer
/// tokens. Fully separate from the handoff-session token family and from the
/// pull-allowance meter — browsing is free by design.
public actor ContinuityLibraryServer {
    public static let authLifetime: TimeInterval = 30
    /// While the host user decides the consent prompt, the pending auth (and
    /// the client's 202 poll loop) lives on this clock instead.
    public static let approvalLifetime: TimeInterval = 120

    private struct PendingAuth {
        let peerId: String
        let peerName: String
        /// Key presented at start — used for verification ONLY when the peer
        /// isn't already trusted (a known peerId can never swap keys).
        let presentedKey: Data
        let nonce: Data
        var expiresAt: Date
        var promptFired = false
        var decision: Decision = .undecided

        enum Decision { case undecided, granted, denied }
    }

    private let identity: ContinuityPeerIdentity
    private let trustStore: any ContinuityTrustStore
    private let grantStore: any ContinuityLibraryGrantStore
    private let approver: any ContinuityLibraryBrowseApproving
    private let provider: any ContinuityLibraryProviding
    /// Read per request — flipping "Share My Library" off must take effect
    /// immediately, not at next activation.
    private let sharingEnabled: @Sendable () async -> Bool

    private var pendingAuths: [String: PendingAuth] = [:]
    private var validatorsByPeer: [String: BearerTokenValidator] = [:]
    private var routesRegistered = false

    public init(
        identity: ContinuityPeerIdentity,
        trustStore: any ContinuityTrustStore,
        grantStore: any ContinuityLibraryGrantStore,
        approver: any ContinuityLibraryBrowseApproving,
        provider: any ContinuityLibraryProviding,
        sharingEnabled: @escaping @Sendable () async -> Bool
    ) {
        self.identity = identity
        self.trustStore = trustStore
        self.grantStore = grantStore
        self.approver = approver
        self.provider = provider
        self.sharingEnabled = sharingEnabled
    }

    /// Registers the library routes. Call once at server setup; safe to call
    /// again (no-op). Routes answer 404 while sharing is off.
    public func activate(on registrar: any ContinuityRouteRegistrar) {
        guard !routesRegistered else { return }
        routesRegistered = true

        registrar.register(method: "POST", path: ContinuityRoutes.libraryAuthStart) { [weak self] request in
            await self?.handleAuthStart(request) ?? .error(status: 404, message: "unavailable")
        }
        registrar.register(method: "POST", path: ContinuityRoutes.libraryAuthComplete) { [weak self] request in
            await self?.handleAuthComplete(request) ?? .error(status: 404, message: "unavailable")
        }
        registrar.register(method: "GET", path: ContinuityRoutes.libraryManifest) { [weak self] request in
            await self?.handleManifest(request) ?? .error(status: 404, message: "unavailable")
        }
        registrar.register(method: "GET", path: ContinuityRoutes.libraryArt) { [weak self] request in
            await self?.handleArt(request) ?? .error(status: 404, message: "unavailable")
        }
    }

    /// Drops every outstanding library token (sharing toggled off, or the
    /// Trusted Devices list was edited).
    public func revokeAllTokens() {
        validatorsByPeer = [:]
        pendingAuths = [:]
    }

    public func revokeToken(forPeerId peerId: String) {
        validatorsByPeer[peerId] = nil
    }

    // MARK: - Auth handlers

    private func handleAuthStart(_ request: ContinuityHTTPRequest) async -> ContinuityHTTPResponse {
        guard await sharingEnabled() else {
            return .error(status: 404, message: "library sharing unavailable")
        }
        guard let body: ContinuityLibraryMessages.AuthStartRequest = Self.decode(request) else {
            return .error(status: 400, message: "invalid library auth request")
        }
        if await grantStore.grant(forPeerId: body.peerId) == .denied {
            return .error(status: 403, message: "library sharing declined for this device")
        }
        prune()

        let authId = UUID().uuidString
        let nonce = ContinuityPairingMath.makeNonce()
        pendingAuths[authId] = PendingAuth(
            peerId: body.peerId,
            peerName: body.name,
            presentedKey: body.publicKey,
            nonce: nonce,
            expiresAt: Date().addingTimeInterval(Self.authLifetime)
        )
        return Self.encode(ContinuityLibraryMessages.AuthStartResponse(
            authId: authId, serverId: identity.id, nonce: nonce
        ))
    }

    private func handleAuthComplete(_ request: ContinuityHTTPRequest) async -> ContinuityHTTPResponse {
        guard await sharingEnabled() else {
            return .error(status: 404, message: "library sharing unavailable")
        }
        guard let body: ContinuityLibraryMessages.AuthCompleteRequest = Self.decode(request) else {
            return .error(status: 400, message: "invalid library auth completion")
        }
        prune()
        guard var pending = pendingAuths[body.authId],
              pending.expiresAt > Date(),
              pending.peerId == body.peerId else {
            pendingAuths[body.authId] = nil
            return .error(status: 410, message: "library auth expired or unknown")
        }

        // Stored key wins for trusted peers — verified on EVERY poll.
        let trustedPeer = await trustStore.peer(withId: body.peerId)
        let verifyKey = trustedPeer?.publicKey ?? pending.presentedKey
        guard ContinuityPairingMath.verifyAuth(
            signature: body.signature,
            nonce: pending.nonce,
            peerId: pending.peerId,
            serverId: identity.id,
            publicKey: verifyKey
        ) else {
            pendingAuths[body.authId] = nil
            return .error(status: 403, message: "signature verification failed")
        }

        let grant = await grantStore.grant(forPeerId: body.peerId)
        if grant == .denied {
            pendingAuths[body.authId] = nil
            return .error(status: 403, message: "library sharing declined for this device")
        }
        // Silent path: granted AND still trusted. A grant whose trust was
        // revoked re-prompts instead (removal from Trusted Devices must not
        // leave a silent side door).
        if grant == .everything, trustedPeer != nil {
            pendingAuths[body.authId] = nil
            return mintTokenResponse(peerId: body.peerId)
        }

        // Consent round. Fire the prompt exactly once, then 202 until decided.
        if !pending.promptFired {
            pending.promptFired = true
            pending.expiresAt = Date().addingTimeInterval(Self.approvalLifetime)
            pendingAuths[body.authId] = pending
            let peerName = pending.peerName
            Task { [approver] in
                let decision = await Self.withTimeout(Self.approvalLifetime) {
                    await approver.approveLibraryBrowse(peerName: peerName)
                } ?? ContinuityLibraryBrowseDecision.dontShare
                self.resolveApproval(authId: body.authId, decision: decision)
            }
            return .error(status: 202, message: "waiting for approval on the other device")
        }

        switch pending.decision {
        case .undecided:
            return .error(status: 202, message: "waiting for approval on the other device")
        case .denied:
            pendingAuths[body.authId] = nil
            await grantStore.setGrant(.denied, forPeerId: pending.peerId)
            return .error(status: 403, message: "library sharing declined for this device")
        case .granted:
            pendingAuths[body.authId] = nil
            await grantStore.setGrant(.everything, forPeerId: pending.peerId)
            // TOFU: Share Everything also trusts the device (same rail the
            // continue-request "Always Allow" rides).
            if trustedPeer == nil {
                await trustStore.add(TrustedPeer(
                    id: pending.peerId, name: pending.peerName, publicKey: verifyKey
                ))
            }
            return mintTokenResponse(peerId: pending.peerId)
        }
    }

    private func resolveApproval(authId: String, decision: ContinuityLibraryBrowseDecision) {
        guard var pending = pendingAuths[authId] else { return }
        pending.decision = (decision == .shareEverything) ? .granted : .denied
        pendingAuths[authId] = pending
    }

    private func mintTokenResponse(peerId: String) -> ContinuityHTTPResponse {
        let token = BearerTokenValidator.mintToken()
        validatorsByPeer[peerId] = BearerTokenValidator(token: token)
        return Self.encode(ContinuityLibraryMessages.LibraryTokenResponse(libraryToken: token))
    }

    private func prune() {
        let now = Date()
        pendingAuths = pendingAuths.filter { $0.value.expiresAt > now }
    }

    // MARK: - Manifest / art (Task 4 replaces these bodies)

    private func handleManifest(_ request: ContinuityHTTPRequest) async -> ContinuityHTTPResponse {
        .error(status: 404, message: "not implemented")
    }

    private func handleArt(_ request: ContinuityHTTPRequest) async -> ContinuityHTTPResponse {
        .error(status: 404, message: "not implemented")
    }

    // MARK: - Helpers (same shapes as ContinuityPairingServer's private ones)

    /// nil on timeout. The losing task isn't force-killed (an approval prompt
    /// awaiting a continuation can't be cancelled) — a late answer is simply
    /// dropped, and resolveApproval on a pruned authId no-ops.
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

    private static func decode<T: Decodable>(_ request: ContinuityHTTPRequest) -> T? {
        guard let body = request.body else { return nil }
        return try? JSONDecoder().decode(T.self, from: body)
    }

    private static func encode<T: Encodable>(_ payload: T) -> ContinuityHTTPResponse {
        guard let data = try? JSONEncoder().encode(payload) else {
            return .error(status: 500, message: "encoding failed")
        }
        return .json(data)
    }
}
