/// A discovered iFly instance advertising a handoff session on the local
/// network.
public struct ContinuityPeer: Sendable, Equatable {
    /// Bonjour service instance name (typically the device name).
    public var serviceName: String
    /// Decoded advertisement, nil when the TXT record is malformed or from an
    /// incompatible version.
    public var advertisement: ContinuityAdvertisement?

    public init(serviceName: String, advertisement: ContinuityAdvertisement?) {
        self.serviceName = serviceName
        self.advertisement = advertisement
    }
}
