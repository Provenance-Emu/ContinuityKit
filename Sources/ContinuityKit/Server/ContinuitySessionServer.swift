import Foundation

/// Everything a caller needs to advertise a freshly started session.
public struct ContinuitySessionInfo: Sendable, Equatable {
    public var sessionId: String
    public var token: String
    public var game: GameIdentity

    public init(sessionId: String, token: String, game: GameIdentity) {
        self.sessionId = sessionId
        self.token = token
        self.game = game
    }
}

/// Device-A side of a handoff: owns the session token and serves the
/// manifest / mint / file routes on the host app's web server.
///
/// Routes are registered once (on `activate`) and answer 404 while no session
/// is active, 401 without the current session's bearer token.
public actor ContinuitySessionServer {
    private let fileProvider: any ContinuityFileProviding
    private let minter: any SaveStateMinting
    private let sourceDevice: SourceDevice

    private var validator: BearerTokenValidator?
    private var session: ContinuitySessionInfo?
    private var saveState: SaveStateDescriptor?
    private var lastManifest: ContinuityManifest?
    private var routesRegistered = false

    public init(
        fileProvider: any ContinuityFileProviding,
        minter: any SaveStateMinting,
        sourceDevice: SourceDevice
    ) {
        self.fileProvider = fileProvider
        self.minter = minter
        self.sourceDevice = sourceDevice
    }

    // MARK: - Session lifecycle

    /// Mints a token and opens a session for `game`. Idempotent per game: a
    /// second call replaces the session (and invalidates the old token).
    public func beginSession(game: GameIdentity) -> ContinuitySessionInfo {
        let token = BearerTokenValidator.mintToken()
        let info = ContinuitySessionInfo(sessionId: UUID().uuidString, token: token, game: game)
        validator = BearerTokenValidator(token: token)
        session = info
        saveState = nil
        lastManifest = nil
        return info
    }

    public func endSession() {
        validator = nil
        session = nil
        saveState = nil
        lastManifest = nil
    }

    public var isSessionActive: Bool { session != nil }

    /// The live session's bearer token — what the pairing/auth routes hand to
    /// approved peers. nil when no session is active.
    public var activeToken: String? { session?.token }

    // MARK: - Route registration

    /// Registers the continuity routes. Call once at server setup; safe to
    /// call again (no-op).
    public func activate(on registrar: any ContinuityRouteRegistrar) {
        guard !routesRegistered else { return }
        routesRegistered = true

        registrar.register(method: "GET", path: ContinuityRoutes.manifest) { [weak self] request in
            await self?.handleManifest(request) ?? .error(status: 404, message: "no session")
        }
        registrar.register(method: "POST", path: ContinuityRoutes.mint) { [weak self] request in
            await self?.handleMint(request) ?? .error(status: 404, message: "no session")
        }
        registrar.register(method: "GET", path: ContinuityRoutes.file) { [weak self] request in
            await self?.handleFile(request) ?? .error(status: 404, message: "no session")
        }
    }

    // MARK: - Handlers

    private func authorize(_ request: ContinuityHTTPRequest) -> ContinuityHTTPResponse? {
        guard session != nil, let validator else {
            return .error(status: 404, message: "no active handoff session")
        }
        guard validator.validate(authorizationHeader: request.header("Authorization")) else {
            return .error(status: 401, message: "invalid or missing session token")
        }
        return nil
    }

    private func handleManifest(_ request: ContinuityHTTPRequest) async -> ContinuityHTTPResponse {
        if let denial = authorize(request) { return denial }
        do {
            let manifest = try await buildManifest(extras: requestedExtras(request))
            return .json(try manifest.encoded())
        } catch {
            return .error(status: 500, message: "manifest build failed: \(error)")
        }
    }

    private func handleMint(_ request: ContinuityHTTPRequest) async -> ContinuityHTTPResponse {
        if let denial = authorize(request) { return denial }
        guard let session else { return .error(status: 404, message: "no active handoff session") }
        do {
            saveState = try await minter.mintHandoffState(identity: session.game)
            let manifest = try await buildManifest(extras: requestedExtras(request))
            return .json(try manifest.encoded())
        } catch {
            return .error(status: 500, message: "save state mint failed: \(error)")
        }
    }

    private func requestedExtras(_ request: ContinuityHTTPRequest) -> Set<FileKind> {
        ContinuityRoutes.extras(fromQueryValue: request.query[ContinuityRoutes.extrasQueryKey])
    }

    private func handleFile(_ request: ContinuityHTTPRequest) async -> ContinuityHTTPResponse {
        if let denial = authorize(request) { return denial }
        guard let relativePath = request.query[ContinuityRoutes.filePathQueryKey], !relativePath.isEmpty else {
            return .error(status: 400, message: "missing ?\(ContinuityRoutes.filePathQueryKey)=")
        }
        // Only manifest-listed files are servable — the manifest is the
        // allowlist, so no path can escape the session's payload. The
        // allowlist is the SUPERSET manifest (extras inlined) so opt-in
        // texture files are servable whenever the client asked for them.
        let manifest: ContinuityManifest
        do {
            manifest = try await allowlistManifest()
        } catch {
            return .error(status: 500, message: "manifest build failed: \(error)")
        }
        guard let descriptor = manifest.descriptor(forRelativePath: relativePath) else {
            return .error(status: 404, message: "not part of this session")
        }
        do {
            let url = try await fileProvider.fileURL(for: descriptor)
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

    // MARK: - Manifest assembly

    /// The file route's allowlist: always the superset (all opt-in kinds
    /// inlined), so what a client can PULL never depends on which manifest
    /// variant it fetched last.
    private func allowlistManifest() async throws -> ContinuityManifest {
        if let lastManifest { return lastManifest }
        return try await buildManifest(extras: FileKind.optInKinds)
    }

    private func buildManifest(extras: Set<FileKind>) async throws -> ContinuityManifest {
        guard let session else { throw ContinuityError.noActiveSession }
        let manifest = try await ContinuityManifestBuilder(
            fileProvider: fileProvider, sourceDevice: sourceDevice
        ).build(
            game: session.game,
            sessionId: session.sessionId,
            saveState: saveState,
            includeTexturePackFiles: extras.contains(.texturePack),
            includeAllVMUFiles: extras.contains(.vmuAll)
        )
        // Cache only the superset — see allowlistManifest.
        if extras.isSuperset(of: FileKind.optInKinds) {
            lastManifest = manifest
        }
        return manifest
    }
}
