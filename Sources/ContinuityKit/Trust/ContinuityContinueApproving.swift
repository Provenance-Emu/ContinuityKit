import Foundation

/// The serving user's answer to a code-less continue request.
public enum ContinuityContinueDecision: Sendable {
    /// Hand out the session token this once; the peer stays untrusted.
    case allowOnce
    /// Hand out the token AND remember the peer (trust-on-first-use with the
    /// public key the request carried) — future requests auth silently.
    case allowAlways
    case deny
}

/// Host-side hook for the always-discoverable flow: a peer on the LAN asked to
/// continue the running game without pairing first. Show "peerName wants to
/// continue — Allow?" and resolve with the user's decision. Unlike pairing
/// there is no code to compare: this grants one session pull (or, with
/// `.allowAlways`, durable trust on first use). The code-verified pairing flow
/// remains the strong path for hostile networks.
public protocol ContinuityContinueApproving: Sendable {
    func approveContinue(peerName: String) async -> ContinuityContinueDecision
}
