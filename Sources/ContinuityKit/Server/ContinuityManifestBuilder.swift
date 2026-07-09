import Foundation

/// Assembles a ContinuityManifest from a file provider. Shared by the network
/// session server (texture packs summarized as optional extras, save state
/// minted separately) and the `.iflypkg` package writer (save states and
/// texture packs inlined as ordinary file entries).
public struct ContinuityManifestBuilder: Sendable {
    private let fileProvider: any ContinuityFileProviding
    private let sourceDevice: SourceDevice

    public init(fileProvider: any ContinuityFileProviding, sourceDevice: SourceDevice) {
        self.fileProvider = fileProvider
        self.sourceDevice = sourceDevice
    }

    /// - Parameters:
    ///   - saveState: the minted "boot this one" state (network path), also
    ///     honored by packages as the auto-resume pointer.
    ///   - includeSaveStateFiles: inline every save state the provider
    ///     enumerates as `.saveState` file entries (package export).
    ///   - includeTexturePackFiles: inline texture-pack files instead of
    ///     summarizing them as an opt-in extra (package export with textures).
    public func build(
        game: GameIdentity,
        sessionId: String,
        saveState: SaveStateDescriptor? = nil,
        includeSaveStateFiles: Bool = false,
        includeTexturePackFiles: Bool = false
    ) async throws -> ContinuityManifest {
        var files: [FileDescriptor] = []
        files += try await fileProvider.enumerate(kind: .gameFile, identity: game)
        files += try await fileProvider.enumerate(kind: .vmuPerGame, identity: game)
        files += try await fileProvider.enumerate(kind: .vmuGlobal, identity: game)
        if includeSaveStateFiles {
            // Exclude the pointer state — it's carried by `saveState` itself.
            let states = try await fileProvider.enumerate(kind: .saveState, identity: game)
            files += states.filter { $0.relativePath != saveState?.relativePath }
        }

        let bios = try await fileProvider.enumerate(kind: .bios, identity: game)

        let texturePacks = try await fileProvider.enumerate(kind: .texturePack, identity: game)
        var extras: [OptionalExtra] = []
        if includeTexturePackFiles {
            files += texturePacks
        } else if !texturePacks.isEmpty {
            extras.append(OptionalExtra(
                kind: .texturePack,
                label: "Texture pack",
                totalSize: texturePacks.reduce(0) { $0 + $1.size },
                fileCount: texturePacks.count
            ))
        }

        return ContinuityManifest(
            sessionId: sessionId,
            mintedAt: Date(),
            sourceDevice: sourceDevice,
            game: game,
            saveState: saveState,
            files: files,
            bios: bios,
            optionalExtras: extras
        )
    }
}
