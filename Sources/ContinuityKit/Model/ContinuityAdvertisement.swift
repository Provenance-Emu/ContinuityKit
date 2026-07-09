import Foundation

/// What device A broadcasts so device B can find and authenticate the session.
/// Carried in the NSUserActivity userInfo (iOS/iPadOS/macOS Handoff) and in
/// the Bonjour TXT record (tvOS and the in-app browse path).
///
/// Trust model (phase 3): the Handoff activity is same-user and private, so
/// it carries the token inline. The Bonjour TXT record is LAN-visible, so it
/// is published REDACTED (empty token) — receivers obtain the token via
/// trusted-peer auth or the code-verified pairing flow.
public struct ContinuityAdvertisement: Codable, Hashable, Sendable {
    public var payloadVersion: Int
    public var sessionId: String
    public var token: String
    public var game: GameIdentity
    public var saveStateStem: String?
    /// Candidate base URLs for the session server, most-preferred first
    /// (Bonjour .local hostname, then raw IP fallbacks).
    public var urlCandidates: [URL]

    public init(
        payloadVersion: Int = ContinuityManifest.currentVersion,
        sessionId: String,
        token: String,
        game: GameIdentity,
        saveStateStem: String? = nil,
        urlCandidates: [URL]
    ) {
        self.payloadVersion = payloadVersion
        self.sessionId = sessionId
        self.token = token
        self.game = game
        self.saveStateStem = saveStateStem
        self.urlCandidates = urlCandidates
    }
}

extension ContinuityAdvertisement: Identifiable {
    /// Session-scoped identity (drives SwiftUI sheet presentation).
    public var id: String { sessionId }
}

extension ContinuityAdvertisement {
    /// True when the receiver must pair/authenticate to obtain the token.
    public var requiresPairing: Bool { token.isEmpty }

    /// LAN-safe copy for the Bonjour TXT record: everything but the token.
    public func redactedForBonjour() -> ContinuityAdvertisement {
        var copy = self
        copy.token = ""
        return copy
    }
}

// MARK: - NSUserActivity userInfo bridging

extension ContinuityAdvertisement {
    /// The custom activity type. Must be listed in the app's
    /// `NSUserActivityTypes` Info.plist array on every receiving platform.
    public static let activityType = "com.joemattiello.ifly.continuity.play"

    private enum UserInfoKey {
        static let payload = "continuityAdvertisement"
    }

    /// Plist-safe encoding for `NSUserActivity.userInfo` / `addUserInfoEntries`.
    public var userInfoRepresentation: [String: Any] {
        guard let data = try? JSONEncoder().encode(self) else { return [:] }
        return [UserInfoKey.payload: data]
    }

    public init?(userInfo: [AnyHashable: Any]?) {
        guard
            let data = userInfo?[UserInfoKey.payload] as? Data,
            let decoded = try? JSONDecoder().decode(ContinuityAdvertisement.self, from: data)
        else { return nil }
        self = decoded
    }
}
