import UIKit
import AVFoundation

// Spotify keeps its own player and queue. Index the canonical playlist folders;
// never flatten their files into Documents or navigate through Local Files.
actor PWNativeFileImport {
    static let shared = PWNativeFileImport()
    private struct Record: Codable {
        var filename: String; var source: String; var size: Int; var modified: Date
        var uri: String; var title: String; var artist: String; var album: String; var duration: Double
        var canonical: Bool?; var legacyBackup: String?
    }
    private var records: [String: Record]?
    private var support: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("PWDownloads") }
    private var manifest: URL { support.appendingPathComponent("native-import.json") }
    private var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    private var tail: Task<Void, Never>?
    private func load() { if records == nil { records = (try? JSONDecoder().decode([String: Record].self, from: Data(contentsOf: manifest))) ?? [:] } }
    private func persist() throws {
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try JSONEncoder().encode(records ?? [:]).write(to: manifest, options: .atomic)
    }
    func prepare(_ entry: PWLocalEntry) async throws -> [String: Any] {
        let prior = tail
        let work = Task { await prior?.value; return try await prepareFile(entry) }
        tail = Task { _ = try? await work.value }
        return try await work.value
    }
    private func prepareFile(_ entry: PWLocalEntry) async throws -> [String: Any] {
        load()
        let location = try entry.location(), scoped = location.root.startAccessingSecurityScopedResource()
        defer { if scoped { location.root.stopAccessingSecurityScopedResource() } }
        let values = try location.file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .ubiquitousItemDownloadingStatusKey])
        guard (values.fileSize ?? 0) > 1024, values.ubiquitousItemDownloadingStatus == nil || values.ubiquitousItemDownloadingStatus == .current else { throw pwError("Le fichier doit être présent sur l’iPhone pour le lire hors connexion.") }
        try await PWNativeFolderScanner.register(root: location.root, directory: location.file.deletingLastPathComponent())
        let fm = FileManager.default, modified = values.contentModificationDate ?? .distantPast
        let old = records?[entry.track.id]
        if let saved = old, saved.canonical == true, saved.source == location.file.path,
           saved.size == values.fileSize, saved.modified == modified { return descriptor(saved) }
        var asset = AVURLAsset(url: location.file, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        var tags = try await asset.load(.commonMetadata)
        func text(_ key: AVMetadataKey, _ values: [AVMetadataItem]) async throws -> String {
            guard let item = values.first(where: { $0.commonKey == key }) else { return "" }
            return try await item.load(.stringValue) ?? ""
        }
        if try await text(.commonKeyTitle, tags).isEmpty {
            let tagged = try await PWAudioTags.tag(location.file, track: entry.track, match: nil)
            defer { try? fm.removeItem(at: tagged) }
            _ = try fm.replaceItemAt(location.file, withItemAt: tagged)
            asset = AVURLAsset(url: location.file, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]); tags = try await asset.load(.commonMetadata)
        }
        let title = try await text(.commonKeyTitle, tags), artist = try await text(.commonKeyArtist, tags), album = try await text(.commonKeyAlbumName, tags)
        let duration = try await asset.load(.duration).seconds
        guard let uri = PWNativeLocalIdentity.uri(artist: artist, album: album, title: title, duration: duration) else { throw pwError("Spotify ne peut pas identifier ce fichier : titre ou durée absent.") }
        let latest = try location.file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        var record = Record(filename: entry.filename, source: location.file.path, size: latest.fileSize ?? 0,
            modified: latest.contentModificationDate ?? modified, uri: uri, title: title, artist: artist, album: album,
            duration: duration, canonical: true, legacyBackup: old?.legacyBackup)
        // Remove only a known import from the previous manifest, after folder
        // registration. Keep a reversible private backup until the native engine
        // confirms the canonical file path. Never delete user-created files.
        if let old = old, old.canonical != true, PWLibraryCatalog.safeComponent(old.filename) {
            let legacy = documents.appendingPathComponent(old.filename)
            if legacy.standardizedFileURL != location.file.standardizedFileURL,
               fm.fileExists(atPath: legacy.path), fm.contentsEqual(atPath: legacy.path, andPath: location.file.path) {
                let folder = support.appendingPathComponent("legacy-import-backups", isDirectory: true)
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                let name = UUID().uuidString + ".m4a"
                // Persist the backup name first, so interruption cannot lose its identity.
                record.legacyBackup = name; records?[entry.track.id] = record; try persist()
                try fm.moveItem(at: legacy, to: folder.appendingPathComponent(name))
                pwEvent("native_flat_import_retired", details: ["retained_private_backup":true])
            } else if fm.fileExists(atPath: legacy.path) {
                pwEvent("native_flat_import_preserved", details: ["reason":"content_differs_or_same_path"])
            }
        }
        records?[entry.track.id] = record; try persist()
        return descriptor(record)
    }
    func confirm(uri: String, filePath: String) {
        load()
        guard !filePath.isEmpty else { return }
        for (id, saved) in records ?? [:] where saved.canonical == true && saved.uri == uri && URL(fileURLWithPath: saved.source).standardizedFileURL.path == URL(fileURLWithPath: filePath).standardizedFileURL.path {
            var record = saved
            guard let name = record.legacyBackup, PWLibraryCatalog.safeComponent(name) else { continue }
            let backup = support.appendingPathComponent("legacy-import-backups").appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: record.source) { try? FileManager.default.removeItem(at: backup); record.legacyBackup = nil; records?[id] = record; try? persist() }
        }
    }
    private func descriptor(_ record: Record) -> [String: Any] {
        let file = URL(fileURLWithPath: record.source)
        PWNativeArtwork.register(uri: record.uri, file: file)
        var metadata = ["title":record.title, "artist_name":record.artist, "album_title":record.album,
            "duration":String(Int(record.duration * 1000)), "has_lyrics":"false"]
        if let image = PWNativeLocalIdentity.artworkURL(file: file)?.absoluteString {
            for key in ["image_url", "image_small_url", "image_large_url", "image_xlarge_url"] { metadata[key] = image }
        }
        return ["uri":record.uri, "metadata":metadata]
    }
}

@MainActor
enum PWNativePlayback {
    static var handler: ((NSDictionary) -> Bool)?
    static var state: [String: Any] = [:]
    static var activePlaylist: String?
    private static var playTask: Task<Void, Never>?
    private static var playRequest = UUID()
    static func importDownloaded(_ entry: PWLocalEntry) {
        Task {
            do {
                _ = handler?(["operation":"enable"])
                _ = try await PWNativeFileImport.shared.prepare(entry)
                pwEvent("native_file_imported")
            } catch { pwEvent("native_file_import_failed", details: PWDownloadLog.error(error)) }
        }
    }
    static func play(_ entries: [PWLocalEntry], at index: Int, title: String, from presenter: UIViewController, playlistURI: String? = nil) {
        guard entries.indices.contains(index) else { return }
        playTask?.cancel()
        let request = UUID(); playRequest = request
        let previousPrompt = presenter.navigationItem.prompt
        if playlistURI == nil { presenter.navigationItem.prompt = "Préparation pour le lecteur Spotify…" }
        playTask = Task { @MainActor [weak presenter] in
            defer {
                if playRequest == request {
                    playTask = nil
                    if playlistURI == nil { presenter?.navigationItem.prompt = previousPrompt }
                }
            }
            do {
                guard handler?(["operation":"enable"]) == true else {
                    throw pwError("Le service audio de Spotify n’est pas encore prêt. Réessaie dans quelques secondes.")
                }
                var tracks: [[String: Any]] = []
                for entry in entries {
                    try Task.checkCancellation()
                    tracks.append(try await PWNativeFileImport.shared.prepare(entry))
                }
                guard let payload = PWNativeLocalIdentity.context(tracks: tracks, title: title, index: index, playlistURI: playlistURI),
                      let target = tracks[index]["uri"] as? String else { throw pwError("Liste de fichiers locaux invalide.") }
                _ = handler?(["operation":"enable"])
                // The native folder index is updated asynchronously.
                try await Task.sleep(nanoseconds: 1_000_000_000)
                try Task.checkCancellation()
                guard playlistURI == nil || PWOfflinePlaylist.enabled else { throw CancellationError() }
                guard handler?(payload as NSDictionary) == true else { throw pwError("Le lecteur Spotify n’a pas accepté cette liste de fichiers locaux.") }
                pwEvent("native_play_requested", tracks.count, details: ["playlist":title, "index":index])
                for _ in 0..<24 {
                    try await Task.sleep(nanoseconds: 500_000_000)
                    if state["uri"] as? String == target, state["playing"] as? Bool == true {
                        activePlaylist = playlistURI
                        pwEvent("native_play_confirmed", details: ["playlist":title])
                        guard let presenter = presenter else { return }
                        let modal = presenter.navigationController ?? presenter
                        if playlistURI != nil { _ = handler?(["operation":"open_player"]) }
                        else if modal.presentingViewController != nil { modal.dismiss(animated: true) { _ = handler?(["operation":"open_player"]) } }
                        else { _ = handler?(["operation":"open_player"]) }
                        return
                    }
                }
                throw pwError("Spotify n’a pas confirmé la lecture du fichier de cette playlist. Exporte les diagnostics pour vérifier l’indexation du dossier et la réponse du lecteur natif.")
            } catch {
                if error is CancellationError || Task.isCancelled { return }
                pwEvent("native_play_failed", details: PWDownloadLog.error(error))
                if let presenter = presenter { PWLocalLibraryController.notice(error.localizedDescription, from: presenter) }
            }
        }
    }
}
extension PWDownloadsBridge {
    @objc(configureNativePlayback:)
    static func configureNativePlayback(_ handler: @escaping (NSDictionary) -> Bool) { PWNativePlayback.handler = handler }
    @objc(nativePlaybackState:)
    static func nativePlaybackState(_ state: NSDictionary) {
        PWNativePlayback.state = state as? [String: Any] ?? [:]
        if !(PWNativePlayback.state["uri"] as? String ?? "").hasPrefix("spotify:local:") { PWNativePlayback.activePlaylist = nil }
        PWNativePlayback.state["updated"] = Date()
        if let uri = PWNativePlayback.state["uri"] as? String, let path = PWNativePlayback.state["file_path"] as? String,
           PWNativePlayback.state["playing"] as? Bool == true {
            Task { await PWNativeFileImport.shared.confirm(uri: uri, filePath: path) }
        }
    }
}
