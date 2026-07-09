import Foundation

public struct ContinuityRequest: Sendable {
    public var url: URL
    public var method: String
    public var headers: [String: String]
    public var body: Data?

    public init(url: URL, method: String = "GET", headers: [String: String] = [:], body: Data? = nil) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
    }

    /// A request carrying the session bearer token.
    public static func authorized(url: URL, method: String = "GET", token: String) -> ContinuityRequest {
        ContinuityRequest(url: url, method: method, headers: ["Authorization": "Bearer \(token)"])
    }
}

public struct ContinuityResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }
}

/// HTTP client abstraction. Production uses URLSessionContinuityTransport;
/// tests use MockTransport (scripted responses, mid-download failure
/// injection).
public protocol ContinuityTransport: Sendable {
    func request(_ request: ContinuityRequest) async throws -> ContinuityResponse

    /// Streams a download to `destination`, appending from `resumeOffset`
    /// (sent as an HTTP Range header when > 0). Returns total bytes on disk
    /// when complete. `progress` reports (bytesOnDisk, expectedTotal?).
    func download(
        _ request: ContinuityRequest,
        to destination: URL,
        resumeOffset: Int64,
        progress: (@Sendable (Int64, Int64?) -> Void)?
    ) async throws -> Int64
}
