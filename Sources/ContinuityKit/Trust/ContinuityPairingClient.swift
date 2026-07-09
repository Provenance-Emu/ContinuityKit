import Foundation

/// Client side of cross-user trust. Two ways to obtain a session token when
/// the advertisement doesn't carry one:
/// - `authenticate` — silent, for peers this device already paired with.
/// - `startPairing` + `completePairing` — first contact; the user types the
///   code shown on the serving device, and completion polls through the
///   server's 202 "waiting for approval" window.
public struct ContinuityPairingClient: Sendable {
    public enum PairingError: Error, Equatable {
        case declined
        case expired
        case wrongCode
        case notPaired
        case noActiveSession
        case invalidResponse(status: Int)
    }

    private let transport: any ContinuityTransport
    /// Poll cadence while the serving user decides (seconds).
    private let approvalPollInterval: TimeInterval

    public init(transport: any ContinuityTransport, approvalPollInterval: TimeInterval = 1.0) {
        self.transport = transport
        self.approvalPollInterval = approvalPollInterval
    }

    // MARK: - Pairing (first contact)

    public func startPairing(
        baseURL: URL,
        identity: ContinuityPeerIdentity
    ) async throws -> ContinuityPairingMessages.PairStartResponse {
        try await post(
            url: baseURL.appendingPathComponent(ContinuityRoutes.pairStart),
            body: ContinuityPairingMessages.PairStartRequest(
                peerId: identity.id, name: identity.name, publicKey: identity.publicKeyData
            )
        )
    }

    /// Computes the proof from the user-entered code and polls completion
    /// until the serving user approves (202 loop), the code is wrong, or the
    /// attempt dies. Returns the session token.
    public func completePairing(
        baseURL: URL,
        start: ContinuityPairingMessages.PairStartResponse,
        code: String,
        identity: ContinuityPeerIdentity
    ) async throws -> String {
        let transcript = ContinuityPairingMath.pairingTranscript(
            pairingId: start.pairingId,
            clientId: identity.id,
            serverId: start.serverId,
            clientPublicKey: identity.publicKeyData,
            serverPublicKey: start.serverPublicKey
        )
        let request = ContinuityPairingMessages.PairCompleteRequest(
            pairingId: start.pairingId,
            proof: ContinuityPairingMath.pairingProof(code: code, transcript: transcript)
        )
        let url = baseURL.appendingPathComponent(ContinuityRoutes.pairComplete)

        while true {
            try Task.checkCancellation()
            let response = try await rawPost(url: url, body: request)
            switch response.status {
            case 200:
                let payload = try JSONDecoder().decode(
                    ContinuityPairingMessages.SessionTokenResponse.self, from: response.body
                )
                return payload.sessionToken
            case 202:
                try await Task.sleep(nanoseconds: UInt64(approvalPollInterval * 1_000_000_000))
            case 401:
                // Wrong code — the pairing stays alive server-side (attempt
                // budget permitting), so the user can retype it.
                throw PairingError.wrongCode
            case 403:
                throw PairingError.declined
            case 404:
                throw PairingError.noActiveSession
            case 410:
                throw PairingError.expired
            default:
                throw PairingError.invalidResponse(status: response.status)
            }
        }
    }

    // MARK: - Trusted-peer auth (silent)

    /// Signature auth against a server this device previously paired with.
    /// Throws `.notPaired` when the server doesn't know us — callers fall
    /// back to the pairing flow.
    public func authenticate(
        baseURL: URL,
        identity: ContinuityPeerIdentity
    ) async throws -> String {
        let start: ContinuityPairingMessages.AuthStartResponse = try await post(
            url: baseURL.appendingPathComponent(ContinuityRoutes.authStart),
            body: ContinuityPairingMessages.AuthStartRequest(peerId: identity.id),
            notPairedStatus: 403
        )
        let signature = try ContinuityPairingMath.signAuth(
            nonce: start.nonce,
            peerId: identity.id,
            serverId: start.serverId,
            signingKey: identity.signingKey
        )
        let complete: ContinuityPairingMessages.SessionTokenResponse = try await post(
            url: baseURL.appendingPathComponent(ContinuityRoutes.authComplete),
            body: ContinuityPairingMessages.AuthCompleteRequest(
                authId: start.authId, peerId: identity.id, signature: signature
            ),
            notPairedStatus: 403
        )
        return complete.sessionToken
    }

    // MARK: - Transport helpers

    private func rawPost<Body: Encodable>(
        url: URL, body: Body
    ) async throws -> ContinuityResponse {
        var request = ContinuityRequest(url: url, method: "POST")
        request.headers["Content-Type"] = "application/json"
        request.body = try JSONEncoder().encode(body)
        return try await transport.request(request)
    }

    private func post<Body: Encodable, Reply: Decodable>(
        url: URL, body: Body, notPairedStatus: Int? = nil
    ) async throws -> Reply {
        let response = try await rawPost(url: url, body: body)
        switch response.status {
        case 200:
            return try JSONDecoder().decode(Reply.self, from: response.body)
        case let status where status == notPairedStatus:
            throw PairingError.notPaired
        case 404:
            throw PairingError.noActiveSession
        case 410:
            throw PairingError.expired
        default:
            throw PairingError.invalidResponse(status: response.status)
        }
    }
}
