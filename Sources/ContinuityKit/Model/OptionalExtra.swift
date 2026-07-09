/// Summarizes an opt-in payload group (texture packs, all-VMU set) so the
/// receiving device can prompt with sizes before pulling.
public struct OptionalExtra: Codable, Hashable, Sendable {
    public var kind: FileKind
    public var label: String
    public var totalSize: Int64
    public var fileCount: Int

    public init(kind: FileKind, label: String, totalSize: Int64, fileCount: Int) {
        self.kind = kind
        self.label = label
        self.totalSize = totalSize
        self.fileCount = fileCount
    }
}
