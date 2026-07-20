import Foundation

/// Same-iCloud device matching: the `ic` TXT key is the first 16 hex chars of
/// SHA-256(salt + CloudKit userRecordID.recordName). The salt is a fixed
/// app-wide constant — every device of the same iCloud account computes the
/// same value with zero coordination, and the truncated salted hash never
/// exposes the raw record name on the LAN.
///
/// Threat-model note (accepted in the 2026-07-19 spec): the hash is broadcast
/// in the TXT record, so a LAN observer could replay it to ride the
/// same-iCloud auth shortcut. The CloudKit-mediated key exchange that closes
/// this is explicitly deferred; the shortcut still requires a valid Ed25519
/// signature and never overrides a `.denied` grant.
public enum ContinuityICloudHash {
    /// Fixed app-wide salt. NEVER change this — a change silently un-pairs
    /// every same-iCloud fleet in the field.
    private static let salt = "iFly-continuity-ic-v1|"

    public static func hash(userRecordName: String) -> String {
        String(ContinuityHash.sha256Hex(of: Data((salt + userRecordName).utf8)).prefix(16))
    }
}
