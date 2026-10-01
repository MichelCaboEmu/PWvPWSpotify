import Foundation
import AVFoundation
import UIKit

// One bounded, credential-free metadata session. No Spotify/YouTube account data.
final class PWMetadataHTTP: NSObject, URLSessionTaskDelegate {
    static let shared = PWMetadataHTTP()
    static func allowed(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        return url.scheme == "https" && url.user == nil && url.password == nil &&
            (host == "itunes.apple.com" || host.hasSuffix(".mzstatic.com") || host == "i.scdn.co" || host == "api.spotify.com" || host == "musicbrainz.org" || host == "coverartarchive.org" || host == "archive.org" || host.hasSuffix(".archive.org"))
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard request.url.map(Self.allowed) == true else { completionHandler(nil); return }
        var clean = request; clean.setValue(nil, forHTTPHeaderField: "Authorization"); clean.setValue(nil, forHTTPHeaderField: "Cookie")
        completionHandler(clean)
    }
    func data(_ url: URL, maximum: Int, authorization: String? = nil) async throws -> Data {
        guard Self.allowed(url) else { throw pwError("Source de métadonnées non autorisée.") }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20; config.timeoutIntervalForResource = 30
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.setValue("PWvPWSpotify/1.0 (https://github.com/MichelCaboEmu/PWvPWSpotify)", forHTTPHeaderField: "User-Agent")
        if url.host == "api.spotify.com" { request.setValue(authorization, forHTTPHeaderField: "Authorization") }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw pwError("Réponse de métadonnées invalide.") }
        pwEvent("metadata_http", http.statusCode, details: ["provider": url.host ?? "metadata"])
        if url.host == "api.spotify.com", [401, 403].contains(http.statusCode) { PWMetadata.spotifyAuthorization = nil }
        guard http.statusCode == 200 else { throw pwError("Métadonnées \(url.host ?? "source") : HTTP \(http.statusCode).") }
        var data = Data()
        for try await byte in bytes {
            if data.count >= maximum { throw pwError("Réponse de métadonnées trop volumineuse.") }
            data.append(byte)
        }
        return data
    }
}
enum PWMetadata {
    static var spotifyAuthorization: String?
    static func artwork(_ text: String?) async -> Data? {
        guard let text = text, let url = URL(string: text), PWMetadataHTTP.allowed(url),
              let bytes = try? await PWMetadataHTTP.shared.data(url, maximum: 4 * 1024 * 1024),
              let image = UIImage(data: bytes), image.size.width <= 2048, image.size.height <= 2048 else { return nil }
        return image.jpegData(compressionQuality: 0.92)
    }
    static func nativeMatch(_ track: PWAudioTrack) async -> PWMetadataMatch? {
        let image = await artwork(track.artworkURL)
        guard track.album != nil || image != nil || track.year != nil else { return nil }
        return PWMetadataMatch(title: track.title, artist: track.artist, album: track.album, year: track.year, artwork: image, source: "Spotify")
    }
    static func lookup(_ original: PWAudioTrack) async throws -> PWMetadataMatch? {
        var track = original
        // Resolve by exact Spotify ID first, including old downloads that had no album.
        if let authorization = spotifyAuthorization, PWDownloadRules.identifier(track.id, length: 22) {
            do {
                let data = try await PWMetadataHTTP.shared.data(URL(string: "https://api.spotify.com/v1/tracks/" + track.id)!, maximum: 512 * 1024, authorization: authorization)
                if let row = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let resolved = PWDownloadRules.tracks([["track": row]]).first, resolved.id == track.id {
                    track = track.enriched(with: resolved)
                }
            } catch { pwEvent("metadata_spotify_unavailable", details: PWDownloadLog.error(error)) }
        }
        var result = await nativeMatch(track)
        if result?.artwork != nil && result?.year != nil { return result }
        let countries = Array(NSOrderedSet(array: [Locale.current.regionCode ?? "FR", "FR", "US"])) as? [String] ?? ["FR"]
        for (attempt, country) in countries.enumerated() {
            try Task.checkCancellation()
            if attempt > 0 { try await Task.sleep(nanoseconds: 3_200_000_000) }
            var url = URLComponents(string: "https://itunes.apple.com/search")!
            url.queryItems = [URLQueryItem(name: "term", value: track.title + " " + track.artist),
                URLQueryItem(name: "entity", value: "song"), URLQueryItem(name: "limit", value: "100"), URLQueryItem(name: "country", value: country)]
            do {
                let data = try await PWMetadataHTTP.shared.data(url.url!, maximum: 4 * 1024 * 1024)
                let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                guard let row = PWMetadataRules.appleMatch(object?["results"] as? [[String: Any]] ?? [], track: track) else { continue }
                let artURL = (row["artworkUrl100"] as? String)?.replacingOccurrences(of: "100x100bb", with: "600x600bb")
                let image = result?.artwork == nil ? await artwork(artURL) : result?.artwork
                let year = (row["releaseDate"] as? String).map { String($0.prefix(4)) }
                return PWMetadataMatch(title: track.title, artist: track.artist, album: track.album ?? row["collectionName"] as? String,
                    year: track.year ?? year, artwork: image, source: result == nil ? "Apple iTunes" : "Spotify + Apple iTunes")
            } catch { pwEvent("metadata_apple_unavailable", details: PWDownloadLog.error(error)) }
        }
        // MusicBrainz offers recording/release identity and Cover Art Archive artwork.
        do {
            if let mb = try await musicBrainz(track) {
                result = PWMetadataMatch(title: track.title, artist: track.artist, album: result?.album ?? mb.album,
                    year: result?.year ?? mb.year, artwork: result?.artwork ?? mb.artwork,
                    source: result == nil ? mb.source : "Spotify + " + mb.source)
            }
        } catch { pwEvent("metadata_musicbrainz_unavailable", details: PWDownloadLog.error(error)) }
        try Task.checkCancellation()
        return result
    }
    static func musicBrainz(_ track: PWAudioTrack) async throws -> PWMetadataMatch? {
        func quote(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        var url = URLComponents(string: "https://musicbrainz.org/ws/2/recording")!
        let query = track.isrc.map { "isrc:" + quote($0) } ?? "recording:" + quote(track.title) + " AND artist:" + quote(track.artist)
        url.queryItems = [URLQueryItem(name: "query", value: query), URLQueryItem(name: "fmt", value: "json"), URLQueryItem(name: "limit", value: "25")]
        // This path issues one MB request per track, following the batch's 3.2s spacing.
        let data = try await PWMetadataHTTP.shared.data(url.url!, maximum: 4 * 1024 * 1024)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        var releases: [[String: Any]] = []
        for row in object?["recordings"] as? [[String: Any]] ?? [] {
            let artist = (row["artist-credit"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }.joined(separator: " ")
            let candidate = PWAudioCandidate(id: "", title: row["title"] as? String ?? "", artist: artist, duration: (row["length"] as? Double ?? 0) / 1000)
            guard PWDownloadRules.rejection(candidate, for: track, requireYouTubeID: false) == nil,
                  PWDownloadRules.titleWords(candidate.title) == PWDownloadRules.titleWords(track.title) else { continue }
            releases += (row["releases"] as? [[String: Any]] ?? []).filter {
                PWMetadataRules.albumMatches($0["title"] as? String, track.album) && $0["status"] as? String == "Official" &&
                !(($0["release-group"] as? [String: Any])?["secondary-types"] as? [String] ?? []).contains("Compilation")
            }
        }
        if track.album == nil && Set(releases.compactMap { ($0["title"] as? String).map(PWDownloadRules.words) }).count > 1 { return nil }
        let rows = releases.sorted { ($0["date"] as? String ?? "9999") < ($1["date"] as? String ?? "9999") }
        guard let release = rows.first else { return nil }
        var image: Data?
        for row in rows.prefix(3) {
            guard let id = row["id"] as? String, UUID(uuidString: id) != nil else { continue }
            image = await artwork("https://coverartarchive.org/release/" + id + "/front-500")
            if image != nil { break }
        }
        return PWMetadataMatch(title: track.title, artist: track.artist, album: release["title"] as? String,
            year: (release["date"] as? String).map { String($0.prefix(4)) }, artwork: image, source: "MusicBrainz / Cover Art Archive")
    }
    static func tag(_ file: URL, track: PWAudioTrack, match: PWMetadataMatch?) async throws -> URL {
        try await PWAudioTags.tag(file, track: track, match: match)
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
            updated.album = match.album ?? entry.album; updated.year = match.year ?? entry.year; updated.metadataSource = match.source
        }
        NSFileCoordinator().coordinate(writingItemAt: location.file, options: .forReplacing, error: &coordination) { original in
            let staging = original.deletingLastPathComponent().appendingPathComponent(".pw-metadata-" + UUID().uuidString + ".m4a")
            defer { try? FileManager.default.removeItem(at: staging) }
            do {
                try FileManager.default.copyItem(at: tagged, to: staging)
                _ = try FileManager.default.replaceItemAt(original, withItemAt: staging)

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
        let entries = allFiles.sorted { $0.track.title < $1.track.title }
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
