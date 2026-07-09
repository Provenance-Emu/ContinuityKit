import Foundation

/// Route paths for the continuity API, shared by server and client.
public enum ContinuityRoutes {
    public static let manifest = "/api/continuity/manifest"
    public static let mint = "/api/continuity/mint"
    public static let file = "/api/continuity/file"

    public static let filePathQueryKey = "path"

    /// URL for pulling one descriptor from a session server.
    public static func fileURL(base: URL, relativePath: String) -> URL {
        var components = URLComponents(url: base.appendingPathComponent(file), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: filePathQueryKey, value: relativePath)]
        return components?.url ?? base
    }

    public static func manifestURL(base: URL) -> URL {
        base.appendingPathComponent(manifest)
    }

    public static func mintURL(base: URL) -> URL {
        base.appendingPathComponent(mint)
    }
}
