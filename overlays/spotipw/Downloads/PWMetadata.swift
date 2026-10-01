import Foundation
import AVFoundation
import UIKit

// One bounded, credential-free metadata session. No Spotify/YouTube account data.
final class PWMetadataHTTP: NSObject, URLSessionTaskDelegate {
    static let shared = PWMetadataHTTP()
    static func allowed(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        return url.scheme == "https" && url.user == nil && url.password == nil &&
            (host == "itunes.apple.com" || host.hasSuffix(".mzstatic.com"))
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url.map(Self.allowed) == true ? request : nil)
    }
    func data(_ url: URL, maximum: Int) async throws -> Data {
        guard Self.allowed(url) else { throw pwError("Source de métadonnées non autorisée.") }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20; config.timeoutIntervalForResource = 30
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(from: url)
        guard let http = response as? HTTPURLResponse else { throw pwError("Réponse de métadonnées invalide.") }
        pwEvent("metadata_http", http.statusCode, details: ["provider": "itunes"])
        guard http.statusCode == 200 else { throw pwError("Métadonnées Apple : HTTP \(http.statusCode).") }
        var data = Data()
        for try await byte in bytes {
            if data.count >= maximum { throw pwError("Réponse de métadonnées trop volumineuse.") }
            data.append(byte)
        }
        return data
    }
}
struct PWMetadataMatch {
    var title: String
    var artist: String
    var album: String?
    var year: String?
    var artwork: Data?
}
enum PWMetadata {
    static func lookup(_ track: PWAudioTrack) async throws -> PWMetadataMatch? {
        var url = URLComponents(string: "https://itunes.apple.com/search")!
        url.queryItems = [URLQueryItem(name: "term", value: track.title + " " + track.artist),
            URLQueryItem(name: "entity", value: "song"), URLQueryItem(name: "limit", value: "25"),
            URLQueryItem(name: "country", value: Locale.current.regionCode ?? "FR")]
        let bytes = try await PWMetadataHTTP.shared.data(url.url!, maximum: 2 * 1024 * 1024)
        let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
        let matches = (object?["results"] as? [[String: Any]] ?? []).filter { row in
            guard let title = row["trackName"] as? String, let artist = row["artistName"] as? String,
                  let duration = row["trackTimeMillis"] as? Double else { return false }
            let candidate = PWAudioCandidate(id: "", title: title, artist: artist, duration: duration / 1000)
            return PWDownloadRules.rejection(candidate, for: track, requireYouTubeID: false) == nil &&
                PWDownloadRules.titleWords(title) == PWDownloadRules.titleWords(track.title)
        }
        guard let row = matches.min(by: { abs(($0["trackTimeMillis"] as? Double ?? 0) / 1000 - track.duration) < abs(($1["trackTimeMillis"] as? Double ?? 0) / 1000 - track.duration) }) else { return nil }
        var artwork: Data?
        if let text = row["artworkUrl100"] as? String,
           let art = URL(string: text.replacingOccurrences(of: "100x100bb", with: "600x600bb")), PWMetadataHTTP.allowed(art) {
            let bytes = try await PWMetadataHTTP.shared.data(art, maximum: 4 * 1024 * 1024)
            if let image = UIImage(data: bytes), image.size.width <= 2048, image.size.height <= 2048 { artwork = image.jpegData(compressionQuality: 0.92) }
        }
        let year = (row["releaseDate"] as? String).map { String($0.prefix(4)) }.flatMap { Int($0) != nil ? $0 : nil }
        return PWMetadataMatch(title: row["trackName"] as? String ?? track.title, artist: row["artistName"] as? String ?? track.artist,
                               album: row["collectionName"] as? String, year: year, artwork: artwork)
    }
    static func tag(_ file: URL, track: PWAudioTrack, match: PWMetadataMatch?) async throws -> URL {
        let asset = AVURLAsset(url: file, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough),
              export.supportedFileTypes.contains(.m4a) else { throw pwError("Ce fichier ne permet pas la mise à jour des métadonnées sans conversion.") }
        let target = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        var success = false
        defer { if !success { try? FileManager.default.removeItem(at: target) } }
        var tags: [AVMetadataItem] = []
        func text(_ id: AVMetadataIdentifier, _ value: String?) {
            guard let value = value, !value.isEmpty else { return }
            let item = AVMutableMetadataItem(); item.identifier = id; item.value = value as NSString; item.extendedLanguageTag = "und"; tags.append(item)
        }
        text(.commonIdentifierTitle, match?.title ?? track.title)
        text(.commonIdentifierArtist, match?.artist ?? track.artist)
        text(.commonIdentifierAlbumName, match?.album)
        text(.iTunesMetadataReleaseDate, match?.year)
        if let artwork = match?.artwork {
            let item = AVMutableMetadataItem(); item.identifier = .commonIdentifierArtwork; item.value = artwork as NSData; item.dataType = "com.apple.metadata.datatype.JPEG"; tags.append(item)
        }
        let replacing = Set(tags.compactMap(\.identifier))
        let existing = try await asset.load(.metadata)
        export.metadata = existing.filter { $0.identifier.map { !replacing.contains($0) } ?? true } + tags
        export.outputURL = target; export.outputFileType = .m4a
        let timeout = Task { try await Task.sleep(nanoseconds: 60_000_000_000); export.cancelExport() }
        defer { timeout.cancel() }
        try await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in export.exportAsynchronously { continuation.resume() } }
            try Task.checkCancellation()
            guard export.status == .completed else { throw export.error ?? pwError("Mise à jour interrompue ou trop longue ; le fichier original est conservé.") }
        }, onCancel: { export.cancelExport() })
        let output = AVURLAsset(url: target, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let duration = try await output.load(.duration).seconds
        let original = try await asset.load(.duration).seconds
        guard duration.isFinite, abs(duration - original) < 0.25, !((try await output.loadTracks(withMediaType: .audio)).isEmpty) else {
            throw pwError("La vérification audio après mise à jour a échoué ; l’original est conservé.")
        }
        success = true; return target
    }
    static func update(_ entry: PWLocalEntry, match: PWMetadataMatch?) async throws -> PWLocalEntry {
        let location = try entry.location(), scoped = location.root.startAccessingSecurityScopedResource()
        defer { if scoped { location.root.stopAccessingSecurityScopedResource() } }
        let local = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        defer { try? FileManager.default.removeItem(at: local) }
        var coordination: NSError?, operation: Error?
        NSFileCoordinator().coordinate(readingItemAt: location.file, options: [], error: &coordination) { url in
            do { try FileManager.default.copyItem(at: url, to: local) } catch { operation = error }
        }
        if let error = operation ?? coordination { throw error }
        let tagged = try await tag(local, track: entry.track, match: match)
        defer { try? FileManager.default.removeItem(at: tagged) }
        try Task.checkCancellation()
        var updated = entry
        if let match = match {
            updated.track.title = match.title; updated.track.artist = match.artist
            updated.album = match.album; updated.year = match.year; updated.metadataSource = "Apple iTunes"
        }
        NSFileCoordinator().coordinate(writingItemAt: location.file, options: .forReplacing, error: &coordination) { original in
            let staging = original.deletingLastPathComponent().appendingPathComponent(".pw-metadata-" + UUID().uuidString + ".m4a")
            defer { try? FileManager.default.removeItem(at: staging) }
            do {
                try FileManager.default.copyItem(at: tagged, to: staging)
                _ = try FileManager.default.replaceItemAt(original, withItemAt: staging)
                // Rename only this catalog-owned file; never overwrite a namesake.
                let desired = PWDownloadRules.filename(updated.track)
                var destination = original.deletingLastPathComponent().appendingPathComponent(desired)
                if destination != original {
                    let base = String(desired.dropLast(4)); var suffix = 2
                    while FileManager.default.fileExists(atPath: destination.path) {
                        destination = original.deletingLastPathComponent().appendingPathComponent(base + " (\(suffix)).m4a"); suffix += 1
                    }
                    try FileManager.default.moveItem(at: original, to: destination)
                    updated.filename = destination.lastPathComponent
                }
            } catch { operation = error }
        }
        if let error = operation ?? coordination { throw error }
        updated.metadataError = nil
        return updated
    }
}

extension PWLocalLibrary {
    func updateMetadata() {
        if metadataTask != nil { metadataTask?.cancel(); return }
        let entries = catalog.entries.values.sorted { $0.track.title < $1.track.title }
        metadataTask = Task {
            var success = 0, failures = 0, unmatched = 0
            defer { metadataTask = nil; persist() }
            for (index, entry) in entries.enumerated() {
                if Task.isCancelled { metadataStatus = "Arrêté : \(success) mis à jour · \(failures) erreurs"; return }
                metadataStatus = "\(index + 1)/\(entries.count) · \(entry.track.title)"; persist()
                do {
                    guard entry.exists() else { throw pwError("Fichier indisponible sur cet iPhone.") }
                    // ~20 searches/minute, keep within Apple's documented rate.
                    if index > 0 { try await Task.sleep(nanoseconds: 3_200_000_000) }
                    let match = try await PWMetadata.lookup(entry.track)
                    let updated = try await PWMetadata.update(entry, match: match)
                    replace(updated); success += 1
                    if match == nil { unmatched += 1 }
                    pwEvent("metadata_updated", details: ["title": entry.track.title, "matched": match != nil])
                } catch {
                    if Task.isCancelled { metadataStatus = "Mise à jour arrêtée"; return }
                    var failed = entry; failed.metadataError = PWDownloadLog.clean(error.localizedDescription); replace(failed)
                    failures += 1; pwEvent("metadata_failed", details: PWDownloadLog.error(error).merging(["title": entry.track.title]) { _, new in new })
                }
            }
            metadataStatus = "\(success) fichiers mis à jour · \(unmatched) sans complément trouvé · \(failures) erreurs"
        }
    }
}
