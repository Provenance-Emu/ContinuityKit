import Foundation

/// Persistence seam for paired peers. The kit ships FileTrustStore; hosts can
/// substitute a Keychain-backed implementation without touching the protocol.
public protocol ContinuityTrustStore: Sendable {
    func peer(withId id: String) async -> TrustedPeer?
    func allPeers() async -> [TrustedPeer]
    func add(_ peer: TrustedPeer) async
    func removePeer(withId id: String) async
    func removeAll() async
}

/// JSON-file trust store (newest first). The file holds only PUBLIC keys, so
/// plain storage is fine; hosts wanting Keychain semantics implement the
/// protocol themselves.
public actor FileTrustStore: ContinuityTrustStore {
    private let fileURL: URL
    private var cached: [TrustedPeer]?

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func peer(withId id: String) -> TrustedPeer? {
        load().first { $0.id == id }
    }

    public func allPeers() -> [TrustedPeer] {
        load()
    }

    public func add(_ peer: TrustedPeer) {
        var peers = load().filter { $0.id != peer.id }
        peers.insert(peer, at: 0)
        save(peers)
    }

    public func removePeer(withId id: String) {
        save(load().filter { $0.id != id })
    }

    public func removeAll() {
        save([])
    }

    private func load() -> [TrustedPeer] {
        if let cached { return cached }
        let peers = (try? Data(contentsOf: fileURL))
            .flatMap { try? JSONDecoder().decode([TrustedPeer].self, from: $0) } ?? []
        cached = peers
        return peers
    }

    private func save(_ peers: [TrustedPeer]) {
        cached = peers
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(peers)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Trust additions failing silently would be a security-UX trap;
            // surface loudly in debug, degrade to session-only trust in release.
            assertionFailure("FileTrustStore write failed: \(error)")
        }
    }
}
