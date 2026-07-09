public enum FileKind: String, Codable, Hashable, Sendable, CaseIterable {
    case gameFile
    case bios
    case saveState
    case vmuGlobal
    case vmuPerGame
    /// Every VMU card on the device, not just the session game's — the
    /// "bring my whole VMU collection" opt-in.
    case vmuAll
    case texturePack

    /// Kinds pulled without prompting. Texture packs and the all-VMU set are
    /// surfaced as optional extras and require user opt-in.
    public var isRequiredByDefault: Bool {
        switch self {
        case .gameFile, .bios, .saveState, .vmuGlobal, .vmuPerGame:
            return true
        case .texturePack, .vmuAll:
            return false
        }
    }

    /// The opt-in kinds: what the file route's superset allowlist must cover
    /// and what a client may request via `?extras=`.
    public static let optInKinds: Set<FileKind> = Set(allCases.filter { !$0.isRequiredByDefault })

    /// Download ordering: small artifacts first so a mid-transfer server death
    /// leaves the most usable partial payload (state + saves before gigabytes
    /// of disc image).
    public var pullPriority: Int {
        switch self {
        case .saveState: return 0
        case .vmuPerGame: return 1
        case .vmuGlobal: return 2
        case .vmuAll: return 3
        case .bios: return 4
        case .gameFile: return 5
        case .texturePack: return 6
        }
    }
}
