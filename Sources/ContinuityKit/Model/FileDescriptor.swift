import Foundation

/// One transferable file. `relativePath` is relative to the app's documents
/// root on the source device and is recreated verbatim on the receiving device
/// (save states bind to games by filename stem, so layout must survive).
public struct FileDescriptor: Codable, Hashable, Sendable {
    public var kind: FileKind
    public var relativePath: String
    public var sha256: String
    public var size: Int64
    public var modifiedAt: Date?
    public var required: Bool

    public init(
        kind: FileKind,
        relativePath: String,
        sha256: String,
        size: Int64,
        modifiedAt: Date? = nil,
        required: Bool = true
    ) {
        self.kind = kind
        self.relativePath = relativePath
        self.sha256 = sha256
        self.size = size
        self.modifiedAt = modifiedAt
        self.required = required
    }
}
