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
    ///   - includeAllVMUFiles: inline the full VMU-card set (every game's
    ///     cards) instead of summarizing it as an opt-in extra.
    public func build(
        game: GameIdentity,
        sessionId: String,
        saveState: SaveStateDescriptor? = nil,
        includeSaveStateFiles: Bool = false,
        includeTexturePackFiles: Bool = false,
        includeAllVMUFiles: Bool = false
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

        var extras: [OptionalExtra] = []

        // The all-VMU set overlaps the session game's cards (already in
        // `files` as required entries) — only the OTHER games' cards are the
        // opt-in delta, so the prompt's size/count don't overstate.
        let alreadyIncluded = Set(files.map(\.relativePath))
        let allVMU = try await fileProvider.enumerate(kind: .vmuAll, identity: game)
            .filter { !alreadyIncluded.contains($0.relativePath) }
        if includeAllVMUFiles {
            files += allVMU
        } else if !allVMU.isEmpty {
            extras.append(OptionalExtra(
                kind: .vmuAll,
                label: "All VMU cards",
                totalSize: allVMU.reduce(0) { $0 + $1.size },
                fileCount: allVMU.count
            ))
        }

        let texturePacks = try await fileProvider.enumerate(kind: .texturePack, identity: game)
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
