import ContinuityKit
import Foundation

/// File provider over a real (temporary) directory tree: descriptors resolve
/// under `root`, presence checks hash actual bytes on disk — so puller tests
/// exercise genuine file I/O, resume, and verification.
public final class MockFileProvider: ContinuityFileProviding, @unchecked Sendable {
    public let root: URL

    private let lock = NSLock()
    private var enumerated: [FileKind: [FileDescriptor]] = [:]
    private var serveURLs: [String: URL] = [:]

    public init(root: URL) {
        self.root = root
    }

    // MARK: - Scripting

    public func setEnumerated(kind: FileKind, descriptors: [FileDescriptor]) {
        lock.lock(); defer { lock.unlock() }
        enumerated[kind] = descriptors
    }

    /// Server-side source URL for a descriptor (defaults to root/relativePath
    /// when unset).
    public func setServeURL(_ url: URL, forRelativePath relativePath: String) {
        lock.lock(); defer { lock.unlock() }
        serveURLs[relativePath] = url
    }

    /// Writes bytes into the tree and returns a matching descriptor.
    @discardableResult
    public func seedFile(
        kind: FileKind,
        relativePath: String,
        contents: Data,
        required: Bool = true
    ) throws -> FileDescriptor {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url)
        return FileDescriptor(
            kind: kind,
            relativePath: relativePath,
            sha256: ContinuityHash.sha256Hex(of: contents),
            size: Int64(contents.count),
            required: required
        )
    }

    // MARK: - ContinuityFileProviding

    public func enumerate(kind: FileKind, identity: GameIdentity) async throws -> [FileDescriptor] {
        synchronized { enumerated[kind] ?? [] }
    }

    public func fileURL(for descriptor: FileDescriptor) async throws -> URL {
        synchronized {
            serveURLs[descriptor.relativePath] ?? root.appendingPathComponent(descriptor.relativePath)
        }
    }

    public func localStatus(of descriptor: FileDescriptor) async -> LocalFileStatus {
        let url = root.appendingPathComponent(descriptor.relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        guard let hash = try? ContinuityHash.sha256Hex(ofFileAt: url) else { return .presentDiffering }
        return hash == descriptor.sha256 ? .presentMatching : .presentDiffering
    }

    public func destinationURL(for descriptor: FileDescriptor) async throws -> URL {
        root.appendingPathComponent(descriptor.relativePath)
    }

    /// NSLock.lock is `noasync`; funneling through a synchronous helper keeps
    /// the async protocol methods legal.
    private func synchronized<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }
}
