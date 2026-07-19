import Foundation

/// Client side of Nearby Libraries browsing: browse auth (signed nonce,
/// polling through the host's consent window), manifest fetch, and art-thumb
/// fetch. Mirrors ContinuityPairingClient's shapes.
public struct ContinuityLibraryClient: Sendable {
    public enum LibraryBrowseError: Error, Equatable {
        /// Host isn't sharing (or predates the routes) — hide the peer.
        case sharingUnavailable
        /// Host chose Don't Share for this device.
        case declined
        case expired
        /// The host's free pulls are spent for today (metered pull → 429).
        case hostLimitReached
        /// The host declined THIS pull (Ask-Per-Game peer) — browsing stays.
        case pullDeclined
        case invalidResponse(status: Int)
    }

    private let transport: any ContinuityTransport
    private let approvalPollInterval: TimeInterval

    public init(transport: any ContinuityTransport, approvalPollInterval: TimeInterval = 1.0) {
        self.transport = transport
        self.approvalPollInterval = approvalPollInterval
    }

    /// Full browse auth. Silent for granted peers; otherwise polls through
    /// the host's 202 consent window. Returns the library bearer token.
    public func authenticate(
        baseURL: URL,
        identity: ContinuityPeerIdentity
    ) async throws -> String {
        let startResponse = try await post(
            url: baseURL.appendingPathComponent(ContinuityRoutes.libraryAuthStart),
            body: ContinuityLibraryMessages.AuthStartRequest(
                peerId: identity.id, name: identity.name, publicKey: identity.publicKeyData
            )
        )
        guard startResponse.status == 200 else {
            throw Self.mapError(status: startResponse.status)
        }
        let start = try JSONDecoder().decode(
            ContinuityLibraryMessages.AuthStartResponse.self, from: startResponse.body
        )
        let signature = try ContinuityPairingMath.signAuth(
            nonce: start.nonce, peerId: identity.id, serverId: start.serverId,
            signingKey: identity.signingKey
        )
        let completeURL = baseURL.appendingPathComponent(ContinuityRoutes.libraryAuthComplete)
        let completeBody = ContinuityLibraryMessages.AuthCompleteRequest(
            authId: start.authId, peerId: identity.id, signature: signature
        )
        while true {
            try Task.checkCancellation()
            let response = try await post(url: completeURL, body: completeBody)
            switch response.status {
            case 200:
                return try JSONDecoder().decode(
                    ContinuityLibraryMessages.LibraryTokenResponse.self, from: response.body
                ).libraryToken
            case 202:
                try await Task.sleep(nanoseconds: UInt64(approvalPollInterval * 1_000_000_000))
            default:
                throw Self.mapError(status: response.status)
            }
        }
    }

    public func fetchManifest(baseURL: URL, token: String) async throws -> ContinuityLibraryManifest {
        let response = try await transport.request(.authorized(
            url: baseURL.appendingPathComponent(ContinuityRoutes.libraryManifest), token: token
        ))
        guard response.status == 200 else { throw Self.mapError(status: response.status) }
        return try ContinuityLibraryManifest.decoded(from: response.body)
    }

    /// Requests a pull manifest for one library game. Metered on the host —
    /// 429 maps to `.hostLimitReached`. Ask-Per-Game hosts answer 202 while
    /// their owner decides; poll through it like browse auth. A 403 here is
    /// a per-pull decline (`.pullDeclined`), not a browse revocation.
    public func requestPull(baseURL: URL, gameId: String, token: String) async throws -> ContinuityManifest {
        var request = ContinuityRequest(
            url: baseURL.appendingPathComponent(ContinuityRoutes.libraryPull), method: "POST")
        request.headers["Content-Type"] = "application/json"
        request.headers["Authorization"] = "Bearer \(token)"
        request.body = try JSONEncoder().encode(ContinuityLibraryMessages.PullRequest(gameId: gameId))
        while true {
            try Task.checkCancellation()
            let response = try await transport.request(request)
            switch response.status {
            case 200:
                return try ContinuityManifest.decode(from: response.body)
            case 202:
                try await Task.sleep(nanoseconds: UInt64(approvalPollInterval * 1_000_000_000))
            case 403:
                throw LibraryBrowseError.pullDeclined
            default:
                throw Self.mapError(status: response.status)
            }
        }
    }

    public func fetchArt(baseURL: URL, key: String, token: String) async throws -> Data {
        let response = try await transport.request(.authorized(
            url: ContinuityRoutes.libraryArtURL(base: baseURL, key: key), token: token
        ))
        guard response.status == 200 else { throw Self.mapError(status: response.status) }
        return response.body
    }

    private func post<Body: Encodable>(url: URL, body: Body) async throws -> ContinuityResponse {
        var request = ContinuityRequest(url: url, method: "POST")
        request.headers["Content-Type"] = "application/json"
        request.body = try JSONEncoder().encode(body)
        return try await transport.request(request)
    }

    private static func mapError(status: Int) -> LibraryBrowseError {
        switch status {
        case 401, 404: .sharingUnavailable
        case 403: .declined
        case 410: .expired
        case 429: .hostLimitReached
        default: .invalidResponse(status: status)
        }
    }
}
