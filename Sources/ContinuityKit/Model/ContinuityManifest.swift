import Foundation

/// The full description of a handoff session's payload, served by device A at
/// `ContinuityRoutes.manifest`. Versioned: decoding rejects versions this
/// build doesn't understand so old apps fail loudly instead of misparsing.
///
/// The session bearer token is never part of the manifest — it travels only in
/// the `Authorization` header (and the initial advertisement).
public struct ContinuityManifest: Codable, Hashable, Sendable {
    public static let currentVersion = 1
    public static let supportedVersions: ClosedRange<Int> = 1...1

    public var version: Int
    public var sessionId: String
    public var mintedAt: Date
    public var sourceDevice: SourceDevice
    public var game: GameIdentity
    public var saveState: SaveStateDescriptor?
    /// Game files + VMU saves. Save state and BIOS are listed separately.
    public var files: [FileDescriptor]
    public var bios: [FileDescriptor]
    public var optionalExtras: [OptionalExtra]

    public init(
        version: Int = ContinuityManifest.currentVersion,
        sessionId: String,
        mintedAt: Date,
        sourceDevice: SourceDevice,
        game: GameIdentity,
        saveState: SaveStateDescriptor? = nil,
        files: [FileDescriptor] = [],
        bios: [FileDescriptor] = [],
        optionalExtras: [OptionalExtra] = []
    ) {
        self.version = version
        self.sessionId = sessionId
        self.mintedAt = mintedAt
        self.sourceDevice = sourceDevice
        self.game = game
        self.saveState = saveState
        self.files = files
        self.bios = bios
        self.optionalExtras = optionalExtras
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .version)
        guard Self.supportedVersions.contains(version) else {
            throw ContinuityError.manifestVersionUnsupported(found: version)
        }
        self.version = version
        self.sessionId = try container.decode(String.self, forKey: .sessionId)
        self.mintedAt = try container.decode(Date.self, forKey: .mintedAt)
        self.sourceDevice = try container.decode(SourceDevice.self, forKey: .sourceDevice)
        self.game = try container.decode(GameIdentity.self, forKey: .game)
        self.saveState = try container.decodeIfPresent(SaveStateDescriptor.self, forKey: .saveState)
        self.files = try container.decode([FileDescriptor].self, forKey: .files)
        self.bios = try container.decode([FileDescriptor].self, forKey: .bios)
        self.optionalExtras = try container.decode([OptionalExtra].self, forKey: .optionalExtras)
    }

    /// Every transferable descriptor: files + bios + save state.
    public var allDescriptors: [FileDescriptor] {
        var all = files + bios
        if let saveState { all.append(saveState.fileDescriptor) }
        return all
    }

    public func descriptor(forRelativePath relativePath: String) -> FileDescriptor? {
        allDescriptors.first { $0.relativePath == relativePath }
    }

    // MARK: - Wire codec (ISO 8601 dates, stable across devices)

    public static func decode(from data: Data) throws -> ContinuityManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ContinuityManifest.self, from: data)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}
