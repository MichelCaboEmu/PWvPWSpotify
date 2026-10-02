import Foundation
import AVFoundation

// Public read/download endpoints from Audius' published OpenAPI. No account,
// paid key or SoundCloud token. Only creator-enabled, ungated downloads.
final class PWAudius: NSObject, URLSessionTaskDelegate {
    static let shared = PWAudius()
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url?.host == "api.audius.co" && request.url?.scheme == "https" ? request : nil)
    }
    func download(_ track: PWAudioTrack, trace: [String: Any], progress: @escaping @MainActor (String) -> Void) async throws -> URL {
        await progress("Recherche Audius…")
        var url = URLComponents(string: "https://api.audius.co/v1/tracks/search")!
        url.queryItems = [URLQueryItem(name: "query", value: track.title + " " + track.artist),
            URLQueryItem(name: "limit", value: "50"), URLQueryItem(name: "only_downloadable", value: "true")]
        let config = URLSessionConfiguration.ephemeral; config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 20; config.timeoutIntervalForResource = 30
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (stream, response) = try await session.bytes(from: url.url!)
        guard let http = response as? HTTPURLResponse else { throw pwError("Réponse Audius invalide.") }
        pwEvent("audius_search_http", http.statusCode, details: trace)
        guard http.statusCode == 200 else {
            throw PWDownloadError(message: "Audius : HTTP \(http.statusCode). Réessaie plus tard.", pausesQueue: [401, 403, 429].contains(http.statusCode))
        }
        var bytes = Data()
        for try await byte in stream { guard bytes.count < 4 * 1024 * 1024 else { throw pwError("Réponse Audius trop volumineuse.") }; bytes.append(byte) }
        let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
        let rows = object?["data"] as? [[String: Any]] ?? []
        var matches: [(String, Double, Set<String>)] = []
        for row in rows {
            let artist = (row["user"] as? [String: Any])?["name"] as? String ?? ""
            let candidate = PWAudioCandidate(id: row["id"] as? String ?? "", title: row["title"] as? String ?? "", artist: artist, duration: row["duration"] as? Double ?? 0)
            let reason = PWDownloadRules.rejection(candidate, for: track, requireYouTubeID: false)
            let enabled = row["is_downloadable"] as? Bool == true && row["is_download_gated"] as? Bool != true &&
                (row["download_conditions"] == nil || row["download_conditions"] is NSNull)
            pwEvent("audius_candidate", details: trace.merging(["candidate_title": candidate.title, "candidate_artist": artist,
                "rejection": reason ?? (enabled ? "accepted" : "download_not_free")]) { _, new in new })
            guard enabled, reason == nil, !candidate.id.isEmpty, candidate.id.count < 100,
                  candidate.id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { continue }
            matches.append((candidate.id, abs(candidate.duration - track.duration), PWAudiusPolicy.announcedHosts(row)))
        }
        guard let match = matches.sorted(by: { $0.1 < $1.1 }).first else {
            throw pwError("Audius : aucune correspondance sûre téléchargeable gratuitement. Ce catalogue ne contient pas tous les titres de Spotify.")
        }
        await progress("Téléchargement Audius…")
        let media = URL(string: "https://api.audius.co/v1/tracks/" + match.0 + "/download")!
        let allowedHosts = match.2
        let transfer = PWAudioTransfer(allowed: { PWAudiusPolicy.mediaURL($0, announced: allowedHosts) }, report: { event, status, details in
            pwEvent("audius_" + event, status, details: trace.merging(details) { _, new in new })
        }, progress: { bytes, total in Task { @MainActor in
            progress(total > 0 ? "Audius : \(Int(Double(bytes) * 100 / Double(total))) %" : "Audius : \(bytes / 1024) Ko")
        } })
        let raw = try await transfer.download(media)
        defer { try? FileManager.default.removeItem(at: raw) }
        return try await convert(raw, duration: track.duration)
    }
    private func convert(_ raw: URL, duration expected: Double) async throws -> URL {
        // Remove the transfer's M4A extension before probing MP3/WAV originals.
        let probe = raw.deletingPathExtension().appendingPathExtension("audio")
        try FileManager.default.moveItem(at: raw, to: probe)
        defer { try? FileManager.default.removeItem(at: probe) }
        let asset = AVURLAsset(url: probe, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, abs(duration - expected) <= max(8, expected * 0.05),
              let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw pwError("Audius : fichier ou durée incompatible avec le titre demandé.")
        }
        let result = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        var success = false
        defer { if !success { try? FileManager.default.removeItem(at: result) } }
        export.outputURL = result; export.outputFileType = .m4a
        let timeout = Task { try await Task.sleep(nanoseconds: 120_000_000_000); export.cancelExport() }
        defer { timeout.cancel() }
        await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in export.exportAsynchronously { continuation.resume() } }
        }, onCancel: { export.cancelExport() })
        try Task.checkCancellation()
        guard export.status == .completed else { throw export.error ?? pwError("Conversion Audius interrompue.") }
        let output = AVURLAsset(url: result), actual = try await output.load(.duration).seconds
        guard actual.isFinite, abs(actual - duration) < 0.25, !(try await output.loadTracks(withMediaType: .audio)).isEmpty else { throw pwError("Fichier Audius incomplet.") }
        success = true; return result
    }
}
