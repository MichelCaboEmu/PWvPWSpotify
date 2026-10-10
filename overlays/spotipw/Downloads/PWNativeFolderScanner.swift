import Foundation

@MainActor
enum PWNativeFolderScanner {
    typealias Handler = (String, Data, @escaping (Data?) -> Void) -> Void
    static var handler: Handler?
    private static var registered = Set<String>()
    private static var documentsEnabled = false
    private static var access: [String: URL] = [:]
    static func configure(_ value: @escaping Handler) { handler = value }
    private final class Pending {
        var continuation: CheckedContinuation<Data?, Never>?
        init(_ continuation: CheckedContinuation<Data?, Never>) { self.continuation = continuation }
        func finish(_ value: Data?) { let old = continuation; continuation = nil; old?.resume(returning: value) }
    }
    private static func call(_ method: String, _ payload: Data) async throws -> Data? {
        try Task.checkCancellation()
        guard let handler = handler else { throw pwError("L’indexeur Spotify n’est pas encore prêt. Réessaie dans quelques secondes.") }
        let reply: Data? = await withCheckedContinuation { continuation in
            let pending = Pending(continuation)
            handler(method, payload) { response in Task { @MainActor in pending.finish(response) } }
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { pending.finish(nil) }
        }
        try Task.checkCancellation()
        pwEvent("native_scanner_response", details: ["method":method, "reply_bytes":reply?.count ?? 0,
            "result": reply.flatMap(PWNativeFolderProtocol.fields)?.first(where: { $0.tag == 1 && $0.wire == 0 }).map { Int(clamping: $0.number) } ?? -1,
            "timed_out_or_no_response":reply == nil])
        return reply
    }
    static func register(root: URL, directory: URL, expectedURI: String) async throws {
        let path = directory.standardizedFileURL.path
        if registered.contains(path) { return }
        if access[root.path] == nil, root.startAccessingSecurityScopedResource() { access[root.path] = root }
        if !documentsEnabled {
            let reply = try await call("MutateDefaultSource", PWNativeFolderProtocol.documentsPayload)
            documentsEnabled = reply.map(PWNativeFolderProtocol.accepted) ?? false
            pwEvent("native_documents_source", details: ["accepted":documentsEnabled])
        }
        guard let payload = PWNativeFolderProtocol.payload(path: path) else { throw pwError("Chemin du dossier invalide.") }
        let response = try await call("AddFolder", payload)
        if response.map(PWNativeFolderProtocol.accepted) == true {
            registered.insert(path); pwEvent("native_playlist_folder_registered"); return
        }
        // iOS can reject arbitrary folders already covered by its built-in
        // source. Accept actual indexed URIs, never a guessed success flag.
        for attempt in 1...3 {
            try await Task.sleep(nanoseconds: UInt64(attempt) * 500_000_000)
            let reply = try await call("GetTracks", PWNativeFolderProtocol.tracksPayload)
            let indexed = reply.flatMap(PWNativeFolderProtocol.indexedURIs)
            pwEvent("native_index_verification", details: ["attempt":attempt, "indexed":indexed?.count ?? 0,
                "selected_found":indexed?.contains(expectedURI) == true, "documents_enabled":documentsEnabled])
            if indexed?.contains(expectedURI) == true { return }
        }
        throw pwError("Spotify n’a pas encore indexé le fichier de cette playlist. La source Documents a été sollicitée, mais le titre n’apparaît pas dans son index natif. Aucun doublon n’a été créé. Exporte les diagnostics pour voir la réponse de l’indexeur.")
    }
}
extension PWDownloadsBridge {
    @objc(configureNativeFolderScanner:)
    static func configureNativeFolderScanner(_ handler: @escaping PWNativeFolderScanner.Handler) { PWNativeFolderScanner.configure(handler) }
    @objc(nativeFolderPayload:)
    static func nativeFolderPayload(_ path: String) -> Data? { PWNativeFolderProtocol.payload(path: path) }
}
