#if !os(watchOS)
import Foundation
import Network

/// Browses the local network for iFly handoff sessions. This is the trigger
/// path for tvOS (which has no system Handoff) and the in-app fallback
/// everywhere else.
///
/// The service type must be listed in the app's `NSBonjourServices` Info.plist
/// array or browsing silently finds nothing.
public actor ContinuityBrowser {
    public static let serviceType = "_ifly-continuity._tcp"

    private var browser: NWBrowser?
    private var continuation: AsyncStream<[ContinuityPeer]>.Continuation?

    public init() {}

    /// Starts browsing and streams the current peer set on every change.
    /// Restarting replaces any previous stream.
    public func peers() -> AsyncStream<[ContinuityPeer]> {
        stop()
        let (stream, continuation) = AsyncStream.makeStream(of: [ContinuityPeer].self)
        self.continuation = continuation

        let descriptor = NWBrowser.Descriptor.bonjourWithTXTRecord(type: Self.serviceType, domain: nil)
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: descriptor, using: parameters)

        browser.browseResultsChangedHandler = { results, _ in
            let peers = results.map(Self.peer(from:)).sorted { $0.serviceName < $1.serviceName }
            continuation.yield(peers)
        }
        browser.stateUpdateHandler = { state in
            if case .failed = state { continuation.finish() }
        }
        browser.start(queue: DispatchQueue(label: "com.joemattiello.ifly.continuity.browser"))
        self.browser = browser
        return stream
    }

    public func stop() {
        browser?.cancel()
        browser = nil
        continuation?.finish()
        continuation = nil
    }

    private static func peer(from result: NWBrowser.Result) -> ContinuityPeer {
        var name = "Unknown"
        if case .service(let serviceName, _, _, _) = result.endpoint {
            name = serviceName
        }
        var advertisement: ContinuityAdvertisement?
        if case .bonjour(let txt) = result.metadata {
            advertisement = ContinuityTXTRecord.decode(txt.dictionary)
        }
        return ContinuityPeer(serviceName: name, advertisement: advertisement)
    }
}
#endif
