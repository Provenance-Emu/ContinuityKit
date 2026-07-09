import Foundation
import ZIPFoundation

/// Reads/extracts a `.iflypkg`. Only manifest-listed paths are extracted (the
/// manifest is the allowlist — a crafted archive can't traverse outside the
/// documents root), and every extracted file is SHA-256-verified against its
/// descriptor.
public struct ContinuityPackageReader: Sendable {
    public struct ExtractionResult: Sendable, Equatable {
        public var extracted: [FileDescriptor] = []
        /// Already present locally with matching checksums — not rewritten.
        public var skippedExisting: [FileDescriptor] = []
        /// Listed in the manifest but absent from the archive (a partial
        /// export) — the fallback ladder decides whether that's fatal.
        public var missingFromArchive: [FileDescriptor] = []
    }

    private let fileProvider: any ContinuityFileProviding

    public init(fileProvider: any ContinuityFileProviding) {
        self.fileProvider = fileProvider
    }

    /// Reads just the manifest — cheap peek for import preview UI.
    public static func manifest(ofPackageAt url: URL) throws -> ContinuityManifest {
        let archive = try Archive(url: url, accessMode: .read)
        guard let entry = archive.first(where: { $0.path == ContinuityPackage.manifestEntryName }) else {
            throw ContinuityError.invalidResponse(status: 0)
        }
        var data = Data()
        _ = try archive.extract(entry) { chunk in data.append(chunk) }
        return try ContinuityManifest.decode(from: data)
    }

    /// Extracts the package into the provider's file layout. `progress`
    /// reports (completedFiles, totalFiles).
    public func extract(
        packageAt url: URL,
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> (manifest: ContinuityManifest, result: ExtractionResult) {
        let manifest = try Self.manifest(ofPackageAt: url)
        let archive = try Archive(url: url, accessMode: .read)

        var result = ExtractionResult()
        let descriptors = manifest.allDescriptors
        for (index, descriptor) in descriptors.enumerated() {
            try Task.checkCancellation()
            defer { progress?(index + 1, descriptors.count) }

            guard let entry = archive.first(where: { $0.path == descriptor.relativePath }) else {
                result.missingFromArchive.append(descriptor)
                continue
            }
            if await fileProvider.localStatus(of: descriptor) == .presentMatching {
                result.skippedExisting.append(descriptor)
                continue
            }

            let destination = try await fileProvider.destinationURL(for: descriptor)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? FileManager.default.removeItem(at: destination)
            _ = try archive.extract(entry, to: destination)

            let hash = try ContinuityHash.sha256Hex(ofFileAt: destination)
            guard hash == descriptor.sha256 else {
                try? FileManager.default.removeItem(at: destination)
                throw ContinuityError.checksumMismatch(relativePath: descriptor.relativePath)
            }
            result.extracted.append(descriptor)
        }
        return (manifest, result)
    }
}
