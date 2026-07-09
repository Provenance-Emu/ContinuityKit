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
    }

    private static let maxURLCandidates = 4

    public static func encode(_ advertisement: ContinuityAdvertisement) -> [String: String] {
        var txt: [String: String] = [
            Key.version: String(advertisement.payloadVersion),
            Key.sessionId: advertisement.sessionId,
            Key.token: advertisement.token,
            Key.displayName: String(advertisement.game.displayName.prefix(180)),
            Key.platform: advertisement.game.platform
        ]
        if let gid = advertisement.game.flycastGameId { txt[Key.flycastGameId] = gid }
        if let md5 = advertisement.game.md5Hash { txt[Key.md5] = md5 }
        if let serial = advertisement.game.serial { txt[Key.serial] = serial }
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
            let sessionId = txt[Key.sessionId],
            let token = txt[Key.token],
            let displayName = txt[Key.displayName],
            let platform = txt[Key.platform]
        else { return nil }

        var urls: [URL] = []
        for index in 0..<maxURLCandidates {
            guard let raw = txt["\(Key.urlPrefix)\(index)"], let url = URL(string: raw) else { break }
            urls.append(url)
        }

        return ContinuityAdvertisement(
            payloadVersion: version,
            sessionId: sessionId,
            token: token,
            game: GameIdentity(
                flycastGameId: txt[Key.flycastGameId],
                md5Hash: txt[Key.md5],
                serial: txt[Key.serial],
                displayName: displayName,
                platform: platform
            ),
            saveStateStem: txt[Key.stem],
            urlCandidates: urls
        )
    }
}
