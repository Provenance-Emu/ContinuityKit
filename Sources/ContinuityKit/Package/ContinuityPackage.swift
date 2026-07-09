/// The `.iflypkg` shareable game-package format: a ZIP archive holding
/// `manifest.json` (the same versioned ContinuityManifest the network handoff
/// uses) plus every payload file at its manifest-relative path.
///
/// Game files (CHD/zip/…) are STORED uncompressed — disc formats are already
/// compressed and re-deflating gigabytes wastes time for nothing. Accessory
/// files (save states, VMU cards, texture packs, GDI indexes, the manifest)
/// get deflate.
public enum ContinuityPackage {
    public static let fileExtension = "iflypkg"
    /// Exported UTI — must match the app's UTExportedTypeDeclarations.
    public static let typeIdentifier = "com.joemattiello.ifly.package"
    public static let mimeType = "application/x-ifly-package"
    public static let manifestEntryName = "manifest.json"
}
