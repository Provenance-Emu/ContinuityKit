import Foundation

public enum ContinuityError: Error, Equatable, Sendable {
    case serverUnreachable(detail: String?)
    case tokenRejected
    case manifestVersionUnsupported(found: Int)
    case invalidResponse(status: Int)
    case checksumMismatch(relativePath: String)
    case gameNotFoundLocally
    case insufficientToBoot
    case noActiveSession
    case cancelled
}

extension ContinuityError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .serverUnreachable(let detail):
            if let detail { return "The other device could not be reached (\(detail))." }
            return "The other device could not be reached."
        case .tokenRejected:
            return "The other device rejected this session. Start the handoff again."
        case .manifestVersionUnsupported(let found):
            return "The other device uses an unsupported transfer format (version \(found)). Update iFly on both devices."
        case .invalidResponse(let status):
            return "The other device sent an unexpected response (HTTP \(status))."
        case .checksumMismatch(let relativePath):
            return "A transferred file failed verification: \(relativePath)."
        case .gameNotFoundLocally:
            return "This game isn't in the local library and couldn't be transferred."
        case .insufficientToBoot:
            return "Not enough was transferred to start the game on this device."
        case .noActiveSession:
            return "No handoff session is active on the other device."
        case .cancelled:
            return "The transfer was cancelled."
        }
    }
}
