import Foundation

/// What device A broadcasts so device B can find and authenticate the session.
/// Carried in the NSUserActivity userInfo (iOS/iPadOS/macOS Handoff) and in
/// the Bonjour TXT record (tvOS and the in-app browse path).
///
/// Note: on the Bonjour path the token is visible to the local network. That
/// is the phase-1 trust model (same-user LAN); cross-user sharing gets a
/// pairing/approval step before it ever ships.
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
