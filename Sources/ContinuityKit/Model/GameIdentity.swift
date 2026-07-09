import Foundation

/// Identifies a game across devices. No single field is guaranteed present:
/// `flycastGameId` is authoritative (captured on first boot from the core),
/// `md5Hash` covers never-booted library entries, and `serial` (IP.BIN) is the
/// weakest match. Resolution ladder: flycastGameId → md5Hash → serial.
public struct GameIdentity: Codable, Hashable, Sendable {
    public var flycastGameId: String?
    public var md5Hash: String?
    public var serial: String?
    public var displayName: String
    /// Platform slug, e.g. "dreamcast", "naomi", "atomiswave".
    public var platform: String
    public var discNumber: Int?
    public var discGroupKey: String?

    public init(
        flycastGameId: String? = nil,
        md5Hash: String? = nil,
        serial: String? = nil,
        displayName: String,
        platform: String,
        discNumber: Int? = nil,
        discGroupKey: String? = nil
    ) {
        self.flycastGameId = flycastGameId
        self.md5Hash = md5Hash
        self.serial = serial
        self.displayName = displayName
        self.platform = platform
        self.discNumber = discNumber
        self.discGroupKey = discGroupKey
    }

    /// True when at least one strong identifier is present; identities without
    /// any cannot be matched on a remote device and must not be advertised.
    public var hasAnyIdentifier: Bool {
        flycastGameId != nil || md5Hash != nil || serial != nil
    }
}
