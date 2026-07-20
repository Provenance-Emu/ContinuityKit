import Foundation

/// Bonjour TXT codec for ContinuityAdvertisement. Keys are terse (TXT strings
/// cap at 255 bytes each); base URLs ride along explicitly (u0, u1, …) so the
/// browser never has to resolve endpoints itself.
public enum ContinuityTXTRecord {
    private enum Key {
        static let version = "v"
        static let sessionId = "sid"
        static let token = "tok"
        static let flycastGameId = "gid"
        static let md5 = "md5"
        static let serial = "ser"
        static let displayName = "name"
        static let platform = "plat"
        static let stem = "stem"
        static let urlPrefix = "u"
        static let sharesLibrary = "lib"
        static let peerId = "pid"
        static let capabilities = "cap"
        static let deviceType = "dt"
        static let icloudHash = "ic"
    }

    private static let maxURLCandidates = 4

    public static func encode(_ advertisement: ContinuityAdvertisement) -> [String: String] {
        var txt: [String: String] = [
            Key.version: String(advertisement.payloadVersion),
            Key.sessionId: advertisement.sessionId
        ]
        // Game keys only ride on session adverts — a library-presence advert
        // has no game and old receivers (which require name+plat) ignore it.
        if let game = advertisement.game {
            txt[Key.displayName] = String(game.displayName.prefix(180))
            txt[Key.platform] = game.platform
            if let gid = game.flycastGameId { txt[Key.flycastGameId] = gid }
            if let md5 = game.md5Hash { txt[Key.md5] = md5 }
            if let serial = game.serial { txt[Key.serial] = serial }
        }
        // Empty token = pairing required (redacted Bonjour advertisement);
        // the key is omitted rather than published blank.
        if !advertisement.token.isEmpty { txt[Key.token] = advertisement.token }
        if advertisement.sharesLibrary { txt[Key.sharesLibrary] = "1" }
        if let pid = advertisement.peerId { txt[Key.peerId] = pid }
        if let cap = advertisement.capabilities { txt[Key.capabilities] = cap }
        if let dt = advertisement.deviceType { txt[Key.deviceType] = dt }
        if let ic = advertisement.icloudHash { txt[Key.icloudHash] = ic }
        if let stem = advertisement.saveStateStem { txt[Key.stem] = stem }
        for (index, url) in advertisement.urlCandidates.prefix(maxURLCandidates).enumerated() {
            txt["\(Key.urlPrefix)\(index)"] = url.absoluteString
        }
        return txt
    }

    public static func decode(_ txt: [String: String]) -> ContinuityAdvertisement? {
        guard
            let versionString = txt[Key.version],
            let version = Int(versionString),
            let sessionId = txt[Key.sessionId]
        else { return nil }
        // Missing token = the server requires pairing/auth to obtain one.
        let token = txt[Key.token] ?? ""

        // Game keys are present only on session adverts (see encode).
        var game: GameIdentity?
        if let displayName = txt[Key.displayName], let platform = txt[Key.platform] {
            game = GameIdentity(
                flycastGameId: txt[Key.flycastGameId],
                md5Hash: txt[Key.md5],
                serial: txt[Key.serial],
                displayName: displayName,
                platform: platform
            )
        }

        var urls: [URL] = []
        for index in 0..<maxURLCandidates {
            guard let raw = txt["\(Key.urlPrefix)\(index)"], let url = URL(string: raw) else { break }
            urls.append(url)
        }

        return ContinuityAdvertisement(
            payloadVersion: version,
            sessionId: sessionId,
            token: token,
            game: game,
            saveStateStem: txt[Key.stem],
            urlCandidates: urls,
            sharesLibrary: txt[Key.sharesLibrary] == "1",
            peerId: txt[Key.peerId],
            capabilities: txt[Key.capabilities],
            deviceType: txt[Key.deviceType],
            icloudHash: txt[Key.icloudHash]
        )
    }
}
