/// What the receiving device should do after a pull ends — successfully or
/// not. Produced by ContinuityFallbackMachine; the app maps each case to a
/// boot action and user messaging.
public enum ContinuityOutcome: Sendable, Equatable {
    /// Everything required arrived (or was already local): boot the game and
    /// load the pulled save state.
    case proceedWithPulledState
    /// The transfer died partway but the pulled state + a locally available
    /// game are enough. `missing` lists what never arrived (e.g. VMU files) so
    /// the app can warn.
    case proceedWithPulledStatePartial(missing: [FileDescriptor])
    /// No usable pulled state, but the game exists locally with its own save
    /// states: boot and load the most recent local state.
    case bootWithLatestLocalState
    /// Game exists locally but no state survived anywhere: boot fresh.
    case bootFresh
    /// Nothing bootable on this device.
    case failed(ContinuityError)
}
