import Foundation
import ZIPFoundation

/// Writes a `.iflypkg` archive from a manifest: every descriptor the file
/// provider can serve, streamed from disk (never buffered whole).
public struct ContinuityPackageWriter: Sendable {
    private let fileProvider: any ContinuityFileProviding

    public init(fileProvider: any ContinuityFileProviding) {
        self.fileProvider = fileProvider
    }

    /// Creates the package at `destination` (replacing any existing file).
    /// `progress` reports (completedFiles, totalFiles).
    public func write(
        manifest: ContinuityManifest,
        to destination: URL,
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws {
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let archive = try Archive(url: destination, accessMode: .create)

        let manifestData = try manifest.encoded()
        try archive.addEntry(
            with: ContinuityPackage.manifestEntryName,
            type: .file,
            uncompressedSize: Int64(manifestData.count),
            compressionMethod: .deflate,
            provider: { position, size in
                manifestData.subdata(in: Int(position) ..< Int(position) + size)
            }
        )

        let descriptors = manifest.allDescriptors
        for (index, descriptor) in descriptors.enumerated() {
            try Task.checkCancellation()
            let source = try await fileProvider.fileURL(for: descriptor)
            try archive.addEntry(
                with: descriptor.relativePath,
                fileURL: source,
                compressionMethod: Self.compressionMethod(for: descriptor)
            )
            progress?(index + 1, descriptors.count)
        }
    }

    /// Disc images are already compressed (CHD, zip romsets) or huge raw data
    /// not worth the CPU on-device; everything else deflates well.
    public static func compressionMethod(for descriptor: FileDescriptor) -> CompressionMethod {
        descriptor.kind == .gameFile ? .none : .deflate
    }
}
