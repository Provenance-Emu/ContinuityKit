/// Minimal HTTP Range parsing — enough for download resume ("bytes=N-" and
/// "bytes=N-M"). Multi-range requests are not supported and parse as nil
/// (clients get the full file, which is always correct).
public struct ByteRangeRequest: Sendable, Equatable {
    public var offset: Int64
    /// Inclusive end byte, nil for open-ended.
    public var end: Int64?

    public init(offset: Int64, end: Int64? = nil) {
        self.offset = offset
        self.end = end
    }

    public static func parse(header: String?) -> ByteRangeRequest? {
        guard let header, header.hasPrefix("bytes=") else { return nil }
        let spec = header.dropFirst("bytes=".count)
        guard !spec.contains(",") else { return nil }
        let parts = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let start = Int64(parts[0]), start >= 0 else { return nil }
        if parts[1].isEmpty {
            return ByteRangeRequest(offset: start)
        }
        guard let end = Int64(parts[1]), end >= start else { return nil }
        return ByteRangeRequest(offset: start, end: end)
    }

    /// Byte count to serve from a file of `totalSize`, or nil if the range is
    /// unsatisfiable.
    public func length(totalSize: Int64) -> Int64? {
        guard offset < totalSize else { return nil }
        let lastByte = min(end ?? totalSize - 1, totalSize - 1)
        return lastByte - offset + 1
    }

    /// `Content-Range` header value for a 206 response.
    public func contentRange(totalSize: Int64) -> String? {
        guard let length = length(totalSize: totalSize) else { return nil }
        return "bytes \(offset)-\(offset + length - 1)/\(totalSize)"
    }
}
