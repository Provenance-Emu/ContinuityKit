import Foundation

/// Route paths for the continuity API, shared by server and client.
public enum ContinuityRoutes {
    public static let manifest = "/api/continuity/manifest"
    public static let mint = "/api/continuity/mint"
    public static let file = "/api/continuity/file"

    // Cross-user pairing + trusted-peer auth (phase 3). All POST, JSON bodies.
    public static let pairStart = "/api/continuity/pair/start"
    public static let pairComplete = "/api/continuity/pair/complete"
    public static let authStart = "/api/continuity/auth/start"
    public static let authComplete = "/api/continuity/auth/complete"

    public static let filePathQueryKey = "path"
    /// Comma-separated FileKind raw values the client wants inlined in the
    /// manifest beyond the defaults (currently just "texturePack").
    public static let extrasQueryKey = "extras"

    /// URL for pulling one descriptor from a session server.
    public static func fileURL(base: URL, relativePath: String) -> URL {
        var components = URLComponents(url: base.appendingPathComponent(file), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: filePathQueryKey, value: relativePath)]
        return components?.url ?? base
    }

    public static func manifestURL(base: URL, extras: Set<FileKind> = []) -> URL {
        appendingExtras(base.appendingPathComponent(manifest), extras: extras)
    }

    public static func mintURL(base: URL, extras: Set<FileKind> = []) -> URL {
        appendingExtras(base.appendingPathComponent(mint), extras: extras)
    }

    private static func appendingExtras(_ url: URL, extras: Set<FileKind>) -> URL {
        guard !extras.isEmpty else { return url }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let value = extras.map(\.rawValue).sorted().joined(separator: ",")
        components?.queryItems = [URLQueryItem(name: extrasQueryKey, value: value)]
        return components?.url ?? url
    }

    /// Parses the extras query value ("texturePack,foo" → known kinds).
    public static func extras(fromQueryValue value: String?) -> Set<FileKind> {
        guard let value, !value.isEmpty else { return [] }
        return Set(value.split(separator: ",").compactMap { FileKind(rawValue: String($0)) })
    }
}
