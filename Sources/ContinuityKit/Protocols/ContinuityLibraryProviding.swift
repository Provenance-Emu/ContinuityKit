import Foundation

/// Host app's seam feeding the library routes: the full-library manifest and
/// artwork file resolution by opaque key. Implementations decide storage
/// (iFly: SwiftData GameEntry store + the artwork disk cache).
public protocol ContinuityLibraryProviding: Sendable {
    func libraryManifest() async throws -> ContinuityLibraryManifest
    func artworkFileURL(forKey key: String) async -> URL?
}
