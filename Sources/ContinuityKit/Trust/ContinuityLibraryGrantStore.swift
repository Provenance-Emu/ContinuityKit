import Foundation

/// What a host lets one specific peer do with its library. Everything and
/// Ask-Per-Game both browse silently once trusted — Ask-Per-Game's control
/// point is the per-pull approval prompt, not re-consenting every browse.
public enum ContinuityLibraryGrant: String, Codable, Sendable {
    case everything
    case askPerGame
    case denied
}

/// Persistence seam for per-peer library grants. Deliberately SEPARATE from
/// ContinuityTrustStore: a denied peer must be remembered without becoming
/// trusted for game pulls (trust-store membership is what authorizes the
/// pull auth routes).
public protocol ContinuityLibraryGrantStore: Sendable {
    func grant(forPeerId id: String) async -> ContinuityLibraryGrant?
    func setGrant(_ grant: ContinuityLibraryGrant, forPeerId id: String) async
    func removeGrant(forPeerId id: String) async
    func removeAll() async
    /// Every remembered decision, peerId -> grant. Needed so the owner can SEE
    /// and undo them: a "Don't Share" is persisted forever, and without a way
    /// to list it a single mis-tap kills the feature with no recovery short of
    /// reinstalling the app.
    func allGrants() async -> [String: ContinuityLibraryGrant]
}

/// JSON-file grant store, mirroring FileTrustStore (plain storage is fine —
/// the file holds no key material, just peerId → grant strings).
public actor FileLibraryGrantStore: ContinuityLibraryGrantStore {
    private let fileURL: URL
    private var cached: [String: ContinuityLibraryGrant]?

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func grant(forPeerId id: String) -> ContinuityLibraryGrant? {
        load()[id]
    }

    public func setGrant(_ grant: ContinuityLibraryGrant, forPeerId id: String) {
        var grants = load()
        grants[id] = grant
        save(grants)
    }

    public func removeGrant(forPeerId id: String) {
        var grants = load()
        grants[id] = nil
        save(grants)
    }

    public func removeAll() {
        save([:])
    }

    public func allGrants() -> [String: ContinuityLibraryGrant] {
        load()
    }

    private func load() -> [String: ContinuityLibraryGrant] {
        if let cached { return cached }
        let grants = (try? Data(contentsOf: fileURL))
            .flatMap { try? JSONDecoder().decode([String: ContinuityLibraryGrant].self, from: $0) } ?? [:]
        cached = grants
        return grants
    }

    private func save(_ grants: [String: ContinuityLibraryGrant]) {
        cached = grants
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try JSONEncoder().encode(grants).write(to: fileURL, options: .atomic)
        } catch {
            // Grant writes failing silently would be a security-UX trap;
            // surface loudly in debug, degrade to session-only grants in release.
            assertionFailure("FileLibraryGrantStore write failed: \(error)")
        }
    }
}
