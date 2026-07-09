/// Broadcasts an active handoff session so other devices can discover it. The
/// app provides platform implementations: NSUserActivity (iOS/iPadOS/macOS
/// Handoff) and a Bonjour TXT record on `_ifly-continuity._tcp` (tvOS has no
/// system Handoff, so browse is its only trigger).
public protocol ContinuityAdvertising: Sendable {
    func publish(_ advertisement: ContinuityAdvertisement) async
    func withdraw() async
}
