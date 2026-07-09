/// Registers continuity routes on the host app's HTTP server. The app adapter
/// wraps NativeWebServer.addCustomHandler and implements streaming for
/// `.file` response bodies (serveFile precedent).
public protocol ContinuityRouteRegistrar: Sendable {
    func register(
        method: String,
        path: String,
        handler: @escaping @Sendable (ContinuityHTTPRequest) async -> ContinuityHTTPResponse
    )
}
