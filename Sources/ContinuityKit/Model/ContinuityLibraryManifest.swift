import Foundation

/// What a sharing host tells a browsing peer about its whole library —
/// titles, platforms, md5s (for the "in your library" match), sizes, art
/// keys, and inventory counts. Served by ContinuityLibraryServer at
/// `ContinuityRoutes.libraryManifest`; art thumbs load lazily per `artKey`.
public struct ContinuityLibraryManifest: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public var version: Int
    /// The host's stable pairing-identity id (ContinuityPeerIdentity.id).
    public var peerId: String
    public var deviceName: String
    public var games: [Game]

    public struct Game: Codable, Sendable, Equatable, Identifiable {
        public var title: String
        public var platform: String
        /// Lowercased md5 when the host has hashed the ROM; nil otherwise.
        public var md5: String?
        public var sizeBytes: Int64
        /// Opaque artwork key — fetch via `ContinuityRoutes.libraryArtURL`.
        /// Clients must not parse it.
        public var artKey: String?
        public var saveStateCount: Int
        /// nil until the P2 Copy… flow wires VMU-file association.
        public var vmuFileCount: Int?

        // MARK: Owner-side library state (all OPTIONAL, added 2026-08-13)
        //
        // These describe the SERVING user's relationship to the game, and they
        // exist so a browsing client can sort and group a remote library the
        // same way it sorts its own. All optional on purpose: a peer running an
        // older build simply omits them and still decodes, and the client can
        // tell "this peer didn't tell me" (nil) from "never played" (a real
        // value) — which matters, because silently sorting a whole library by
        // a uniformly-nil field looks like a bug to the user.
        //
        // They are the OWNER's values, never the viewer's. The browsing client
        // must present them as the peer's ("Their Favorites") and must not let
        // browsing mutate its own library state.
        public var lastPlayedDate: Date?
        public var playCount: Int?
        public var favorite: Bool?
        public var addedDate: Date?

        public var id: String { md5 ?? "\(title)|\(platform)|\(sizeBytes)" }

        public init(title: String, platform: String, md5: String?, sizeBytes: Int64,
                    artKey: String?, saveStateCount: Int, vmuFileCount: Int?,
                    lastPlayedDate: Date? = nil, playCount: Int? = nil,
                    favorite: Bool? = nil, addedDate: Date? = nil) {
            self.title = title
            self.platform = platform
            self.md5 = md5
            self.sizeBytes = sizeBytes
            self.artKey = artKey
            self.saveStateCount = saveStateCount
            self.vmuFileCount = vmuFileCount
            self.lastPlayedDate = lastPlayedDate
            self.playCount = playCount
            self.favorite = favorite
            self.addedDate = addedDate
        }
    }

    public init(version: Int = ContinuityLibraryManifest.currentVersion,
                peerId: String, deviceName: String, games: [Game]) {
        self.version = version
        self.peerId = peerId
        self.deviceName = deviceName
        self.games = games
    }

    public func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    public static func decoded(from data: Data) throws -> ContinuityLibraryManifest {
        try JSONDecoder().decode(ContinuityLibraryManifest.self, from: data)
    }
}
