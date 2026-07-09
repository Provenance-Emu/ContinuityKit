/// Produces a fresh save state for the current game on demand. Minting is
/// lazy: device B's first call to the mint route triggers this, so the state
/// is seconds old when pulled — no periodic autosave overhead.
///
/// The app implementation pauses the emulator, saves to the dedicated handoff
/// slot, and reports the flycast-derived stem (Naomi/arcade stems can diverge
/// from the game path basename — the descriptor's stem is authoritative).
public protocol SaveStateMinting: Sendable {
    func mintHandoffState(identity: GameIdentity) async throws -> SaveStateDescriptor
}
