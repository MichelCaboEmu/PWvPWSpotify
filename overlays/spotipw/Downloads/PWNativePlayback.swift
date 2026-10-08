import UIKit
import AVFoundation

// Spotify owns audio, player state, remote commands and queue. This component
// only exposes downloaded files to its existing Documents scanner and hands it
// a finite local context. It never creates a second player or player UI.
actor PWNativeFileImport {
    static let shared = PWNativeFileImport()
    private struct Record: Codable { var filename: String; var source: String; var size: Int; var modified: Date; var uri: String; var title: String; var artist: String; var album: String; var duration: Double }
    private var records: [String: Record]?
    private var manifest: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("PWDownloads/native-import.json") }
    private var directory: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    private var tail: Task<Void, Never>?
    func prepare(_ entry: PWLocalEntry) async throws -> [String: Any] {
        let prior = tail
        let work = Task { await prior?.value; return try await prepareFile(entry) }
        tail = Task { _ = try? await work.value }
        return try await work.value
    }
    private func prepareFile(_ entry: PWLocalEntry) async throws -> [String: Any] {
        if records == nil { records = (try? JSONDecoder().decode([String: Record].self, from: Data(contentsOf: manifest))) ?? [:] }
        let location = try entry.location(), scoped = location.root.startAccessingSecurityScopedResource()
        defer { if scoped { location.root.stopAccessingSecurityScopedResource() } }
        let values = try location.file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .ubiquitousItemDownloadingStatusKey])
        guard (values.fileSize ?? 0) > 1024, values.ubiquitousItemDownloadingStatus == nil || values.ubiquitousItemDownloadingStatus == .current else { throw pwError("Le fichier doit être présent sur l’iPhone pour le lire hors connexion.") }
        let fm = FileManager.default, modified = values.contentModificationDate ?? .distantPast
        if let saved = records?[entry.track.id], PWLibraryCatalog.safeComponent(saved.filename), saved.source == location.file.path, saved.size == values.fileSize,
           saved.modified == modified, fm.fileExists(atPath: directory.appendingPathComponent(saved.filename).path) {
            _ = PWSharedAudioFile.consolidate(location.file, target: directory.appendingPathComponent(saved.filename))
            return descriptor(saved)
        }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let existing = records?[entry.track.id]
        var name = existing?.filename ?? entry.filename
        if existing == nil {
            let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
            var suffix = 2
            while fm.fileExists(atPath: directory.appendingPathComponent(name).path) {
                name = "\(base) (\(suffix)).\(ext)"; suffix += 1
            }
        }
        guard PWLibraryCatalog.safeComponent(name) else { throw pwError("Nom de fichier local invalide.") }
        // Staging outside Documents prevents Spotify scanning an incomplete copy.
        let staging = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        defer { try? fm.removeItem(at: staging) }
        let shared = try PWSharedAudioFile.materialize(location.file, at: staging)
        pwEvent("native_import_storage", details: ["mode": shared ? "shared" : "copy"])
        var asset = AVURLAsset(url: staging, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        var tags = try await asset.load(.commonMetadata)
        func text(_ key: AVMetadataKey, _ values: [AVMetadataItem]) async throws -> String {
            guard let item = values.first(where: { $0.commonKey == key }) else { return "" }
            return try await item.load(.stringValue) ?? ""
        }
        if try await text(.commonKeyTitle, tags).isEmpty {
            let tagged = try await PWAudioTags.tag(staging, track: entry.track, match: nil)
            defer { try? fm.removeItem(at: tagged) }
            try fm.removeItem(at: staging); try fm.moveItem(at: tagged, to: staging)
            asset = AVURLAsset(url: staging, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]); tags = try await asset.load(.commonMetadata)
        }
        let title = try await text(.commonKeyTitle, tags), artist = try await text(.commonKeyArtist, tags), album = try await text(.commonKeyAlbumName, tags)
        let duration = try await asset.load(.duration).seconds
        guard let uri = PWNativeLocalIdentity.uri(artist: artist, album: album, title: title, duration: duration) else { throw pwError("Spotify ne peut pas identifier ce fichier local : titre ou durée absent.") }
        let target = directory.appendingPathComponent(name)
        if fm.fileExists(atPath: target.path) { _ = try fm.replaceItemAt(target, withItemAt: staging) }
        else { try fm.moveItem(at: staging, to: target) }
        let record = Record(filename: name, source: location.file.path, size: values.fileSize ?? 0, modified: modified, uri: uri, title: title, artist: artist, album: album, duration: duration)
        records?[entry.track.id] = record
        try fm.createDirectory(at: manifest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(records ?? [:]).write(to: manifest, options: .atomic)
        return descriptor(record)
    }
    private func descriptor(_ record: Record) -> [String: Any] {
        PWNativeArtwork.register(uri: record.uri, filename: record.filename)
        var metadata = ["title":record.title, "artist_name":record.artist,
            "album_title":record.album, "duration":String(Int(record.duration * 1000)), "has_lyrics":"false"]
        if let image = PWNativeLocalIdentity.artworkURL(file: directory.appendingPathComponent(record.filename))?.absoluteString {
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
                _ = try await PWNativeFileImport.shared.prepare(entry)
                _ = handler?(["operation":"enable"])
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
                    throw pwError("L’import des fichiers locaux Spotify n’est pas encore prêt. Ouvre Bibliothèque → Fichiers locaux, puis réessaie.")
                }
                var tracks: [[String: Any]] = []
                for entry in entries {
                    try Task.checkCancellation()
                    tracks.append(try await PWNativeFileImport.shared.prepare(entry))
                }
                guard let payload = PWNativeLocalIdentity.context(tracks: tracks, title: title, index: index, playlistURI: playlistURI),
                      let target = tracks[index]["uri"] as? String else { throw pwError("Liste de fichiers locaux invalide.") }
                _ = handler?(["operation":"enable"])
                // The native scanner discovers moved files asynchronously.
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
                throw pwError("Spotify n’a pas confirmé la lecture. Ses fichiers locaux peuvent être encore en cours d’indexation. Ouvre Bibliothèque → Fichiers locaux et vérifie que le titre y apparaît. Aucun autre lecteur n’a été lancé.")
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
    }
}
