import Foundation

/// Server-side request as seen by continuity route handlers, decoupled from
/// the host app's web server implementation.
public struct ContinuityHTTPRequest: Sendable {
    public var method: String
    public var path: String
    public var query: [String: String]
    public var headers: [String: String]
    public var body: Data?

    public init(
        method: String,
        path: String,
        query: [String: String] = [:],
        headers: [String: String] = [:],
        body: Data? = nil
    ) {
        self.method = method
        self.path = path
        self.query = query
        self.headers = headers
        self.body = body
    }

    /// Case-insensitive header lookup (HTTP header names are case-insensitive;
    /// hosts differ in what they preserve).
    public func header(_ name: String) -> String? {
        if let exact = headers[name] { return exact }
        let lowered = name.lowercased()
        return headers.first { $0.key.lowercased() == lowered }?.value
    }
}

public struct ContinuityHTTPResponse: Sendable {
    /// Bodies are either in-memory (JSON) or a file reference the host server
    /// streams from disk — game files run to gigabytes and must never be
    /// loaded into memory.
    public enum Body: Sendable {
        case empty
        case data(Data)
        case file(url: URL, offset: Int64, length: Int64?)
    }

    public var status: Int
    public var contentType: String
    public var headers: [String: String]
    public var body: Body

    public init(status: Int, contentType: String = "application/json", headers: [String: String] = [:], body: Body = .empty) {
        self.status = status
        self.contentType = contentType
        self.headers = headers
        self.body = body
    }

    public static func json(_ data: Data, status: Int = 200) -> ContinuityHTTPResponse {
        ContinuityHTTPResponse(status: status, contentType: "application/json", body: .data(data))
    }

    public static func error(status: Int, message: String) -> ContinuityHTTPResponse {
        let payload = (try? JSONSerialization.data(withJSONObject: ["error": message])) ?? Data()
        return ContinuityHTTPResponse(status: status, contentType: "application/json", body: .data(payload))
    }
}
