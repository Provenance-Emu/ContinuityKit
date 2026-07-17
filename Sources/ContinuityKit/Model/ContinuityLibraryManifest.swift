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

        public var id: String { md5 ?? "\(title)|\(platform)|\(sizeBytes)" }

        public init(title: String, platform: String, md5: String?, sizeBytes: Int64,
                    artKey: String?, saveStateCount: Int, vmuFileCount: Int?) {
            self.title = title
            self.platform = platform
            self.md5 = md5
            self.sizeBytes = sizeBytes
            self.artKey = artKey
            self.saveStateCount = saveStateCount
            self.vmuFileCount = vmuFileCount
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
