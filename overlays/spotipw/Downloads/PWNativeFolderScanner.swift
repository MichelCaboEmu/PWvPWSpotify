import Foundation

@MainActor
enum PWNativeFolderScanner {
    static var handler: ((String, @escaping (Data?) -> Void) -> Void)?
    private static var registered = Set<String>()
    private static var access: [String: URL] = [:]
    private static var migrationStarted = false
    static func configure(_ value: @escaping (String, @escaping (Data?) -> Void) -> Void) {
        handler = value
        guard !migrationStarted else { return }
        migrationStarted = true
        Task { @MainActor in
            _ = PWDownloadStore.shared
            // Allow app-created settings and legacy folder organization to settle.
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await PWLocalLibrary.shared.organizationTask?.value
            // Submit one migration at a time, so a user's play request is not
            // stuck behind hundreds of startup import tasks.
            for entry in PWLocalLibrary.shared.allFiles {
                do { _ = try await PWNativeFileImport.shared.prepare(entry) }
                catch { pwEvent("native_file_import_failed", details: PWDownloadLog.error(error)) }
            }
        }
    }
    private final class Pending {
        var continuation: CheckedContinuation<Bool, Never>?
        init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }
        func finish(_ value: Bool) { let old = continuation; continuation = nil; old?.resume(returning: value) }
    }
    static func register(root: URL, directory: URL) async throws {
        let path = directory.standardizedFileURL.path
        if registered.contains(path) { return }
        guard let handler = handler else { throw pwError("L’indexeur Spotify des dossiers de playlists n’est pas encore prêt. Réessaie dans quelques secondes.") }
        // The native scanner outlives a single play request. Keep a user-selected
        // security-scoped folder open for this app session, never for another root.
        if access[root.path] == nil, root.startAccessingSecurityScopedResource() { access[root.path] = root }
        let accepted = await withCheckedContinuation { continuation in
            let pending = Pending(continuation)
            handler(path) { response in
                Task { @MainActor in
                    let ok = response.map(PWNativeFolderProtocol.accepted) ?? false
                    pwEvent("native_playlist_folder_response", details: ["accepted":ok, "reply_bytes":response?.count ?? 0,
                        "result": response?.count == 2 && response?.first == 8 ? Int(response!.last!) : -1])
                    pending.finish(ok)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { pending.finish(false) }
        }
        guard accepted else { throw pwError("Spotify n’a pas accepté l’indexation du dossier de cette playlist. Aucun fichier supplémentaire n’a été créé dans Documents.") }
        registered.insert(path)
        pwEvent("native_playlist_folder_registered")
    }
}
extension PWDownloadsBridge {
    @objc(configureNativeFolderScanner:)
    static func configureNativeFolderScanner(_ handler: @escaping (String, @escaping (Data?) -> Void) -> Void) { PWNativeFolderScanner.configure(handler) }
    @objc(nativeFolderPayload:)
    static func nativeFolderPayload(_ path: String) -> Data? { PWNativeFolderProtocol.payload(path: path) }
}
