import Foundation

/// Which file-download route a pull rides: the handoff-session route or the
/// Nearby Libraries pull route. An enum (not a URL closure) so trailing
/// `progress:` closures at call sites can never bind to it by accident.
public enum PullFileRoute: Sendable {
    /// Session handoff file route (default).
    case session
    /// Nearby Libraries granted-pull file route.
    case library

    func url(base: URL, relativePath: String) -> URL {
        switch self {
        case .session: ContinuityRoutes.fileURL(base: base, relativePath: relativePath)
        case .library: ContinuityRoutes.libraryFileURL(base: base, relativePath: relativePath)
        }
    }
}

/// Device-B side of a handoff: fetches the manifest, diffs it against local
/// files, and pulls what's missing — small artifacts first, with Range-based
/// resume of interrupted downloads and SHA-256 verification of every file.
public actor ContinuityPuller {
    private let transport: any ContinuityTransport
    private let fileProvider: any ContinuityFileProviding

    public init(transport: any ContinuityTransport, fileProvider: any ContinuityFileProviding) {
        self.transport = transport
        self.fileProvider = fileProvider
    }

    // MARK: - Manifest

    /// Asks device A to mint a fresh save state and returns the resulting
    /// manifest. The normal first call of a handoff. `extras` inlines opt-in
    /// kinds (texture packs) as pullable file entries.
    public func mintAndFetchManifest(
        baseURL: URL,
        token: String,
        extras: Set<FileKind> = []
    ) async throws -> ContinuityManifest {
        try await fetchManifest(
            url: ContinuityRoutes.mintURL(base: baseURL, extras: extras),
            method: "POST",
            token: token
        )
    }

    /// Fetches the manifest without minting (re-fetch after a partial pull or
    /// after the user opts into extras).
    public func fetchManifest(
        baseURL: URL,
        token: String,
        extras: Set<FileKind> = []
    ) async throws -> ContinuityManifest {
        try await fetchManifest(
            url: ContinuityRoutes.manifestURL(base: baseURL, extras: extras),
            method: "GET",
            token: token
        )
    }

    private func fetchManifest(url: URL, method: String, token: String) async throws -> ContinuityManifest {
        let response = try await transport.request(.authorized(url: url, method: method, token: token))
        switch response.status {
        case 200:
            return try ContinuityManifest.decode(from: response.body)
        case 401:
            throw ContinuityError.tokenRejected
        case 404:
            throw ContinuityError.noActiveSession
        default:
            throw ContinuityError.invalidResponse(status: response.status)
        }
    }

    // MARK: - Planning

    /// Diffs the manifest against local files. Files whose checksums already
    /// match are skipped; differing or missing files are pulled.
    public func makePlan(for manifest: ContinuityManifest) async -> PullPlan {
        var needed: [FileDescriptor] = []
        var present: [FileDescriptor] = []
        for descriptor in manifest.allDescriptors {
            switch await fileProvider.localStatus(of: descriptor) {
            case .presentMatching:
                present.append(descriptor)
            case .missing, .presentDiffering:
                needed.append(descriptor)
            }
        }
        needed.sort {
            ($0.kind.pullPriority, $0.size, $0.relativePath) < ($1.kind.pullPriority, $1.size, $1.relativePath)
        }
        return PullPlan(needed: needed, alreadyPresent: present, optionalExtras: manifest.optionalExtras)
    }

    // MARK: - Execution

    /// Pulls every file in the plan. Throws PullFailure on the first
    /// unrecoverable error, carrying what completed so the fallback machine
    /// can decide what's still bootable.
    public func execute(
        plan: PullPlan,
        baseURL: URL,
        token: String,
        fileRoute: PullFileRoute = .session,
        progress: (@Sendable (PullProgress) -> Void)? = nil
    ) async throws {
        var completed: [FileDescriptor] = []
        var bytesDone: Int64 = 0
        let totalBytes = plan.totalBytesNeeded

        for (index, descriptor) in plan.needed.enumerated() {
            do {
                try Task.checkCancellation()
                let bytesBeforeFile = bytesDone
                try await pull(
                    descriptor: descriptor,
                    baseURL: baseURL,
                    token: token,
                    fileRoute: fileRoute
                ) { fileBytes, _ in
                    progress?(PullProgress(
                        currentFile: descriptor,
                        completedFiles: index,
                        totalFiles: plan.needed.count,
                        bytesTransferred: bytesBeforeFile + fileBytes,
                        totalBytes: totalBytes
                    ))
                }
                completed.append(descriptor)
                bytesDone += descriptor.size
            } catch is CancellationError {
                throw PullFailure(
                    underlying: .cancelled,
                    completed: completed,
                    missing: Array(plan.needed[index...])
                )
            } catch let error as ContinuityError {
                throw PullFailure(
                    underlying: error,
                    completed: completed,
                    missing: Array(plan.needed[index...])
                )
            } catch {
                throw PullFailure(
                    underlying: .serverUnreachable(detail: String(describing: error)),
                    completed: completed,
                    missing: Array(plan.needed[index...])
                )
            }
        }
    }

    // MARK: - Single file

    private func pull(
        descriptor: FileDescriptor,
        baseURL: URL,
        token: String,
        fileRoute: PullFileRoute,
        progress: @escaping @Sendable (Int64, Int64?) -> Void
    ) async throws {
        let destination = try await fileProvider.destinationURL(for: descriptor)
        let partial = destination.appendingPathExtension("part")
        let fileManager = FileManager.default

        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        // Resume a previous attempt if a partial file is lying around.
        var resumeOffset: Int64 = 0
        if let attrs = try? fileManager.attributesOfItem(atPath: partial.path),
           let size = attrs[.size] as? Int64, size > 0, size < descriptor.size {
            resumeOffset = size
        } else if fileManager.fileExists(atPath: partial.path) {
            try? fileManager.removeItem(at: partial)
        }

        let request = ContinuityRequest.authorized(
            url: fileRoute.url(base: baseURL, relativePath: descriptor.relativePath),
            token: token
        )
        _ = try await transport.download(request, to: partial, resumeOffset: resumeOffset, progress: progress)

        let actualHash = try ContinuityHash.sha256Hex(ofFileAt: partial)
        guard actualHash == descriptor.sha256 else {
            try? fileManager.removeItem(at: partial)
            throw ContinuityError.checksumMismatch(relativePath: descriptor.relativePath)
        }

        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: partial, to: destination)
    }
}
