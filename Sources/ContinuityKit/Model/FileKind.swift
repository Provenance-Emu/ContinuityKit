public enum FileKind: String, Codable, Hashable, Sendable, CaseIterable {
    case gameFile
    case bios
    case saveState
    case vmuGlobal
    case vmuPerGame
    case texturePack

    /// Kinds pulled without prompting. Texture packs (and "all VMUs", which the
    /// provider surfaces as optional extras) require user opt-in.
    public var isRequiredByDefault: Bool {
        switch self {
        case .gameFile, .bios, .saveState, .vmuGlobal, .vmuPerGame:
            return true
        case .texturePack:
            return false
        }
    }

    /// Download ordering: small artifacts first so a mid-transfer server death
    /// leaves the most usable partial payload (state + saves before gigabytes
    /// of disc image).
    public var pullPriority: Int {
        switch self {
        case .saveState: return 0
        case .vmuPerGame: return 1
        case .vmuGlobal: return 2
        case .bios: return 3
        case .gameFile: return 4
        case .texturePack: return 5
        }
    }
}
