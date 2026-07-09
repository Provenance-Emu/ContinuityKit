import Foundation

/// Progress snapshot delivered during ContinuityPuller.execute.
public struct PullProgress: Sendable, Equatable {
    public var currentFile: FileDescriptor
    public var completedFiles: Int
    public var totalFiles: Int
    public var bytesTransferred: Int64
    public var totalBytes: Int64

    public init(
        currentFile: FileDescriptor,
        completedFiles: Int,
        totalFiles: Int,
        bytesTransferred: Int64,
        totalBytes: Int64
    ) {
        self.currentFile = currentFile
        self.completedFiles = completedFiles
        self.totalFiles = totalFiles
        self.bytesTransferred = bytesTransferred
        self.totalBytes = totalBytes
    }

    public var fractionComplete: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(bytesTransferred) / Double(totalBytes)
    }
}
