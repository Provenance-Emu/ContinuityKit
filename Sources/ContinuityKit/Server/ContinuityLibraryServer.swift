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

        enum Decision { case undecided, granted(ContinuityLibraryGrant), denied }
    }

    /// One in-flight Ask-Per-Game pull consent, keyed by peerId|gameId. The
    /// client's 202 poll loop rides this the same way browse auth rides
    /// PendingAuth; an approval is one-shot (consumed by the poll that sees it).
    private struct PendingPullApproval {
        var expiresAt: Date
        var decision: Decision = .undecided

        enum Decision { case undecided, allowed, denied }
    }

    private let identity: ContinuityPeerIdentity
    private let trustStore: any ContinuityTrustStore
    private let grantStore: any ContinuityLibraryGrantStore
    private let approver: any ContinuityLibraryBrowseApproving
    private let provider: any ContinuityLibraryProviding
    /// Read per request — flipping "Share My Library" off must take effect
    /// immediately, not at next activation.
    private let sharingEnabled: @Sendable () async -> Bool
    /// nil = this host can't serve pulls (routes answer 404).
    private let pullProvider: (any ContinuityLibraryPullProviding)?
    /// Consulted per pull for Ask-Per-Game peers. nil = no approval UI is
    /// wired, so Ask-Per-Game pulls are refused outright (never silently allowed).
    private let pullApprover: (any ContinuityLibraryPullApproving)?
    /// Metering seam: consulted once per pull request; false → 429. Browse
    /// routes never touch it — browsing is free by design.
    private let pullPolicy: @Sendable () async -> Bool

    private var pendingAuths: [String: PendingAuth] = [:]
    private var pendingPullApprovals: [String: PendingPullApproval] = [:]
    private var validatorsByPeer: [String: BearerTokenValidator] = [:]
    /// Union of every granted pull manifest's descriptors, by relative path —
    /// the file route's allowlist (same manifest-is-the-allowlist rule the
    /// session server uses). Bounded by library size; cleared with tokens.
    private var pullAllowlist: [String: FileDescriptor] = [:]
    private var routesRegistered = false

    public init(
        identity: ContinuityPeerIdentity,
        trustStore: any ContinuityTrustStore,
        grantStore: any ContinuityLibraryGrantStore,
        approver: any ContinuityLibraryBrowseApproving,
        provider: any ContinuityLibraryProviding,
        sharingEnabled: @escaping @Sendable () async -> Bool,
        pullProvider: (any ContinuityLibraryPullProviding)? = nil,
        pullPolicy: @escaping @Sendable () async -> Bool = { true },
        pullApprover: (any ContinuityLibraryPullApproving)? = nil
    ) {
        self.identity = identity
        self.trustStore = trustStore
        self.grantStore = grantStore
        self.approver = approver
        self.provider = provider
        self.sharingEnabled = sharingEnabled
        self.pullProvider = pullProvider
        self.pullPolicy = pullPolicy
        self.pullApprover = pullApprover
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
        registrar.register(method: "POST", path: ContinuityRoutes.libraryPull) { [weak self] request in
            await self?.handlePull(request) ?? .error(status: 404, message: "unavailable")
        }
        registrar.register(method: "GET", path: ContinuityRoutes.libraryFile) { [weak self] request in
            await self?.handleLibraryFile(request) ?? .error(status: 404, message: "unavailable")
        }
    }

    /// Drops every outstanding library token (sharing toggled off, or the
    /// Trusted Devices list was edited).
    public func revokeAllTokens() {
        validatorsByPeer = [:]
        pendingAuths = [:]
        pendingPullApprovals = [:]
        pullAllowlist = [:]
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
        // leave a silent side door). Ask-Per-Game browses silently too — its
        // control point is the per-pull prompt, not re-consenting every browse.
        if grant == .everything || grant == .askPerGame, trustedPeer != nil {
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
        case .granted(let grantedLevel):
            pendingAuths[body.authId] = nil
            await grantStore.setGrant(grantedLevel, forPeerId: pending.peerId)
            // TOFU: any affirmative grant also trusts the device (same rail
            // the continue-request "Always Allow" rides). Ask-Per-Game needs
            // it doubly — the pull prompt has to name a recognizable peer.
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
        switch decision {
        case .shareEverything: pending.decision = .granted(.everything)
        case .askPerGame: pending.decision = .granted(.askPerGame)
        case .dontShare: pending.decision = .denied
        }
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
        pendingPullApprovals = pendingPullApprovals.filter { $0.value.expiresAt > now }
    }

    // MARK: - Ask-Per-Game pull consent

    /// nil = approved, proceed with the pull. Anything else is the interim
    /// answer for this poll: 202 while the owner decides, 403 on deny (or
    /// when no approval UI is wired — Ask-Per-Game must never silently allow).
    private func runPullApproval(peerId: String, gameId: String) async -> ContinuityHTTPResponse? {
        prune()
        let key = "\(peerId)|\(gameId)"
        if let pending = pendingPullApprovals[key] {
            switch pending.decision {
            case .undecided:
                return .error(status: 202, message: "waiting for approval on the other device")
            case .denied:
                pendingPullApprovals[key] = nil
                return .error(status: 403, message: "pull declined on the other device")
            case .allowed:
                // One approval = one pull manifest; the next pull re-prompts.
                pendingPullApprovals[key] = nil
                return nil
            }
        }
        guard let pullApprover else {
            return .error(status: 403, message: "pull approval unavailable on this host")
        }
        // Name the game from the browse manifest (same Game.id derivation the
        // browser tapped); a stale id falls back to the raw id string.
        let title = (try? await provider.libraryManifest())?
            .games.first { $0.id == gameId }?.title ?? gameId
        let peerName = (await trustStore.peer(withId: peerId))?.name ?? peerId
        pendingPullApprovals[key] = PendingPullApproval(
            expiresAt: Date().addingTimeInterval(Self.approvalLifetime)
        )
        Task { [pullApprover] in
            let decision = await Self.withTimeout(Self.approvalLifetime) {
                await pullApprover.approveLibraryPull(peerName: peerName, gameTitle: title)
            } ?? ContinuityLibraryPullDecision.deny
            await self.resolvePullApproval(key: key, peerId: peerId, decision: decision)
        }
        return .error(status: 202, message: "waiting for approval on the other device")
    }

    private func resolvePullApproval(
        key: String, peerId: String, decision: ContinuityLibraryPullDecision
    ) async {
        guard var pending = pendingPullApprovals[key] else { return }
        switch decision {
        case .allow:
            pending.decision = .allowed
        case .alwaysForDevice:
            pending.decision = .allowed
            // Everything-grant: this and every future pull skip the prompt.
            await grantStore.setGrant(.everything, forPeerId: peerId)
        case .deny:
            pending.decision = .denied
        }
        pendingPullApprovals[key] = pending
    }

    // MARK: - Manifest / art

    /// denial == nil means authorized, and peerId names the token's owner —
    /// the pull route uses it to look up the caller's grant. Sharing off
    /// masks everything as 404; a missing or wrong token is 401.
    private func authorize(
        _ request: ContinuityHTTPRequest
    ) async -> (peerId: String?, denial: ContinuityHTTPResponse?) {
        guard await sharingEnabled() else {
            return (nil, .error(status: 404, message: "library sharing unavailable"))
        }
        let header = request.header("Authorization")
        guard let match = validatorsByPeer.first(where: {
            $0.value.validate(authorizationHeader: header)
        }) else {
            return (nil, .error(status: 401, message: "invalid or missing library token"))
        }
        return (match.key, nil)
    }

    private func handleManifest(_ request: ContinuityHTTPRequest) async -> ContinuityHTTPResponse {
        if let denial = await authorize(request).denial { return denial }
        do {
            let manifest = try await provider.libraryManifest()
            return .json(try manifest.encoded())
        } catch {
            return .error(status: 500, message: "library manifest build failed: \(error)")
        }
    }

    private func handleArt(_ request: ContinuityHTTPRequest) async -> ContinuityHTTPResponse {
        if let denial = await authorize(request).denial { return denial }
        guard let key = request.query[ContinuityRoutes.artKeyQueryKey], !key.isEmpty else {
            return .error(status: 400, message: "missing ?\(ContinuityRoutes.artKeyQueryKey)=")
        }
        // Keys are cache FILENAMES, never paths — reject any traversal shape
        // before the provider touches the filesystem.
        guard !key.contains("/"), !key.contains("\\"), !key.contains("..") else {
            return .error(status: 400, message: "invalid art key")
        }
        guard let url = await provider.artworkFileURL(forKey: key) else {
            return .error(status: 404, message: "no artwork for key")
        }
        return ContinuityHTTPResponse(
            status: 200,
            contentType: "application/octet-stream",
            headers: [:],
            body: .file(url: url, offset: 0, length: nil)
        )
    }

    // MARK: - Pull / file

    private func handlePull(_ request: ContinuityHTTPRequest) async -> ContinuityHTTPResponse {
        let auth = await authorize(request)
        if let denial = auth.denial { return denial }
        guard let peerId = auth.peerId else {
            return .error(status: 401, message: "invalid or missing library token")
        }
        guard let pullProvider else {
            return .error(status: 404, message: "pulls unavailable on this host")
        }
        guard let body: ContinuityLibraryMessages.PullRequest = Self.decode(request) else {
            return .error(status: 400, message: "invalid pull request")
        }
        // Ask-Per-Game peers ride a 202 consent window per pull (same poll
        // rail as browse auth); an interim response short-circuits here.
        if await grantStore.grant(forPeerId: peerId) == .askPerGame,
           let interim = await runPullApproval(peerId: peerId, gameId: body.gameId) {
            return interim
        }
        // The ONLY metered library route: policy false = the host's free
        // pulls are spent (client shows the Pro upsell copy). Consulted
        // AFTER consent — a denied or pending pull must not spend the meter.
        guard await pullPolicy() else {
            return .error(status: 429, message: "host's free pulls used for today")
        }
        do {
            guard let manifest = try await pullProvider.pullManifest(forGameId: body.gameId) else {
                return .error(status: 404, message: "no such library game")
            }
            for descriptor in manifest.allDescriptors {
                pullAllowlist[descriptor.relativePath] = descriptor
            }
            return .json(try manifest.encoded())
        } catch {
            return .error(status: 500, message: "pull manifest build failed: \(error)")
        }
    }

    private func handleLibraryFile(_ request: ContinuityHTTPRequest) async -> ContinuityHTTPResponse {
        if let denial = await authorize(request).denial { return denial }
        guard let pullProvider else {
            return .error(status: 404, message: "pulls unavailable on this host")
        }
        guard let relativePath = request.query[ContinuityRoutes.filePathQueryKey], !relativePath.isEmpty else {
            return .error(status: 400, message: "missing ?\(ContinuityRoutes.filePathQueryKey)=")
        }
        // Granted pull manifests are the allowlist — a path outside them
        // (traversal or guessing) is indistinguishable from absent.
        guard let descriptor = pullAllowlist[relativePath] else {
            return .error(status: 404, message: "not part of a granted pull")
        }
        do {
            guard let url = try await pullProvider.fileURL(forRelativePath: relativePath) else {
                return .error(status: 404, message: "file unavailable")
            }
            if let range = ByteRangeRequest.parse(header: request.header("Range")) {
                guard let length = range.length(totalSize: descriptor.size),
                      let contentRange = range.contentRange(totalSize: descriptor.size) else {
                    return .error(status: 416, message: "range not satisfiable")
                }
                return ContinuityHTTPResponse(
                    status: 206,
                    contentType: "application/octet-stream",
                    headers: ["Content-Range": contentRange, "Accept-Ranges": "bytes"],
                    body: .file(url: url, offset: range.offset, length: length)
                )
            }
            return ContinuityHTTPResponse(
                status: 200,
                contentType: "application/octet-stream",
                headers: ["Accept-Ranges": "bytes"],
                body: .file(url: url, offset: 0, length: nil)
            )
        } catch {
            return .error(status: 404, message: "file unavailable: \(error)")
        }
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
