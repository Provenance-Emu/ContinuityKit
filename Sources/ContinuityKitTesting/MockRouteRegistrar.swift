import ContinuityKit
import Foundation

/// Captures registered routes and lets tests invoke them directly — server
/// tests run against real handlers with no sockets involved.
public final class MockRouteRegistrar: ContinuityRouteRegistrar, @unchecked Sendable {
    public typealias Handler = @Sendable (ContinuityHTTPRequest) async -> ContinuityHTTPResponse

    private let lock = NSLock()
    private var routes: [String: Handler] = [:]

    public init() {}

    public func register(method: String, path: String, handler: @escaping Handler) {
        lock.lock(); defer { lock.unlock() }
        routes["\(method) \(path)"] = handler
    }

    public var registeredRoutes: [String] {
        lock.lock(); defer { lock.unlock() }
        return routes.keys.sorted()
    }

    public func invoke(
        method: String,
        path: String,
        query: [String: String] = [:],
        headers: [String: String] = [:],
        body: Data? = nil
    ) async -> ContinuityHTTPResponse? {
        let handler = synchronized { routes["\(method) \(path)"] }
        guard let handler else { return nil }
        return await handler(ContinuityHTTPRequest(
            method: method,
            path: path,
            query: query,
            headers: headers,
            body: body
        ))
    }

    /// NSLock.lock is `noasync`; funneling through a synchronous helper keeps
    /// the async `invoke` legal.
    private func synchronized<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }
}
