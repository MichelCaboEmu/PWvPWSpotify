import Foundation
import AVFoundation

// Native adapter for SoundCloud's public website protocol, researched in
// yt-dlp/extractor/soundcloud.py. No bundled client ID, OAuth secret or account.
@MainActor
final class PWSoundCloud: NSObject, URLSessionTaskDelegate {
    static let shared = PWSoundCloud()
    private var cachedClient: (date: Date, value: String)?
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void) {
        guard let origin = task.originalRequest?.url, let url = request.url,
              (PWSoundCloudRules.apiURL(origin) && PWSoundCloudRules.apiURL(url)) ||
              (PWSoundCloudRules.webURL(origin) && PWSoundCloudRules.webURL(url)) ||
              (PWSoundCloudRules.mediaURL(origin) && PWSoundCloudRules.mediaURL(url)) else {
            completionHandler(nil); return
        }
        var clean = request; clean.setValue(nil, forHTTPHeaderField: "Authorization"); clean.setValue(nil, forHTTPHeaderField: "Cookie")
        completionHandler(clean)
    }
    private func data(_ url: URL, session: URLSession, stage: String, trace: [String: Any], maximum: Int) async throws -> Data {
        try Task.checkCancellation()
        guard PWSoundCloudRules.apiURL(url) || PWSoundCloudRules.webURL(url) || PWSoundCloudRules.mediaURL(url) else { throw URLError(.unsupportedURL) }
        var request = URLRequest(url: url, timeoutInterval: 25)
        request.httpShouldHandleCookies = false
        request.setValue(PWYouTubeAccess.userAgent, forHTTPHeaderField: "User-Agent")
        let started = Date()
        let (stream, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw pwError("Réponse SoundCloud invalide.") }
        pwEvent("soundcloud_" + stage + "_http", http.statusCode, details: trace.merging([
            "elapsed_ms": Int(Date().timeIntervalSince(started) * 1000), "content_type": http.mimeType ?? "unknown"]) { _, new in new })
        guard http.statusCode == 200 else {
            if http.statusCode == 429 { throw PWDownloadError(message: "SoundCloud limite les demandes (HTTP 429). Réessaie plus tard.", pausesQueue: true) }
            throw PWAudioHTTPError(status: http.statusCode)
        }
        var bytes = Data()
        for try await byte in stream {
            guard bytes.count < maximum else { throw pwError("Réponse SoundCloud trop volumineuse.") }
            bytes.append(byte)
        }
        try Task.checkCancellation()
        return bytes
    }
    private func client(session: URLSession, trace: [String: Any]) async throws -> String {
        if let cached = cachedClient, Date().timeIntervalSince(cached.date) < 3600 { return cached.value }
        let page = try await data(URL(string: "https://soundcloud.com/")!, session: session, stage: "page", trace: trace, maximum: 4 * 1024 * 1024)
        guard let html = String(data: page, encoding: .utf8) else { throw pwError("Page SoundCloud illisible.") }
        for url in PWSoundCloudRules.scripts(html).prefix(8) {
            let bytes = try await data(url, session: session, stage: "configuration", trace: trace, maximum: 6 * 1024 * 1024)
            if let script = String(data: bytes, encoding: .utf8), let value = PWSoundCloudRules.clientID(script) {
                cachedClient = (Date(), value); pwEvent("soundcloud_public_configuration_ready", details: trace); return value
            }
        }
        throw pwError("La configuration publique SoundCloud a changé ou est indisponible. Aucun compte ni abonnement n’a été utilisé.")
    }
    private func json(_ url: URL, session: URLSession, stage: String, trace: [String: Any]) async throws -> [String: Any] {
        for attempt in 1...2 {
            let value = try await client(session: session, trace: trace)
            guard let endpoint = PWSoundCloudRules.endpoint(url, clientID: value) else { throw URLError(.unsupportedURL) }
            do {
                let bytes = try await data(endpoint, session: session, stage: stage, trace: trace, maximum: 4 * 1024 * 1024)
                guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw pwError("Réponse JSON SoundCloud invalide.") }
                return object
            } catch let error as PWAudioHTTPError where error.status == 401 && attempt == 1 {
                // Refresh only an expired public website configuration. A 403,
                // challenge or login wall is reported; no fingerprint evasion.
                cachedClient = nil; pwEvent("soundcloud_public_configuration_expired", 401, details: trace)
            }
        }
        throw pwError("Configuration SoundCloud expirée.")
    }
    func download(_ track: PWAudioTrack, trace: [String: Any], progress: @escaping @MainActor (String) -> Void) async throws -> URL {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.urlCache = nil
        config.timeoutIntervalForRequest = 25; config.timeoutIntervalForResource = 30
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        progress("Recherche SoundCloud…")
        var matches: [PWSoundCloudMatch] = [], seen = Set<String>(), rejected: [String: Int] = [:]
        let queries = [track.title + " " + track.artist, track.artist + " " + track.title]
        for (index, query) in queries.enumerated() {
            var url = URLComponents(string: "https://api-v2.soundcloud.com/search/tracks")!
            url.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "limit", value: "50"),
                URLQueryItem(name: "linked_partitioning", value: "1"), URLQueryItem(name: "offset", value: "0")]
            let searchTrace = trace.merging(["query": query, "search_attempt": index + 1]) { _, new in new }
            let object = try await json(url.url!, session: session, stage: "search", trace: searchTrace)
            let rows = object["collection"] as? [[String: Any]] ?? []
            for row in rows {
                guard let id = (row["id"] as? NSNumber)?.stringValue, seen.insert(id).inserted else { continue }
                let (match, reason) = PWSoundCloudRules.match(row, track: track)
                pwEvent("soundcloud_candidate", details: searchTrace.merging([
                    "candidate_title": row["title"] as? String ?? "", "candidate_artist": (row["user"] as? [String: Any])?["username"] as? String ?? "",
                    "rejection": reason, "evidence": match?.evidence ?? "none"]) { _, new in new })
                if let match = match { matches.append(match) } else { rejected[reason, default: 0] += 1 }
            }
            if !matches.isEmpty { break }
        }
        pwEvent("soundcloud_search_results", matches.count, details: trace.merging([
            "candidates": seen.count, "rejections": rejected.keys.sorted().map { "\($0): \(rejected[$0]!)" }.joined(separator: ", ")]) { _, new in new })
        guard !matches.isEmpty else { throw pwError("SoundCloud : aucune version complète et fiable trouvée. Les extraits, contenus payants, reprises et versions non confirmées sont écartés.") }
        matches.sort { left, right in
            if left.evidence != right.evidence { return left.evidence == "isrc" }
            return abs(left.candidate.duration - track.duration) < abs(right.candidate.duration - track.duration)
        }
        var last: Error = pwError("Aucun flux SoundCloud compatible.")
        for match in matches.prefix(3) {
            for transcoding in match.transcodings.prefix(2) {
                try Task.checkCancellation()
                let candidateTrace = trace.merging(["evidence": match.evidence, "candidate_title": match.candidate.title,
                    "candidate_duration": match.candidate.duration, "protocol": transcoding.protocolName]) { _, new in new }
                do {
                    progress("Extraction SoundCloud…")
                    let object = try await json(transcoding.url, session: session, stage: "stream", trace: candidateTrace)
                    guard let text = object["url"] as? String, let media = URL(string: text), PWSoundCloudRules.mediaURL(media) else {
                        throw pwError("SoundCloud ne fournit pas de flux public complet compatible.")
                    }
                    let raw: URL
                    if transcoding.protocolName == "hls" {
                        raw = try await hls(media, session: session, duration: track.duration, trace: candidateTrace, progress: progress)
                    } else { raw = try await transfer(media, trace: candidateTrace, progress: progress) }
                    defer { try? FileManager.default.removeItem(at: raw) }
                    progress("Vérification du fichier SoundCloud…")
                    let result = try await PWSoundCloudAudio.convert(raw, duration: track.duration)
                    pwEvent("soundcloud_audio_ready", details: candidateTrace)
                    return result
                } catch {
                    try Task.checkCancellation()
                    if (error as? URLError)?.code == .cancelled || (error as? PWDownloadError)?.pausesQueue == true { throw error }
                    last = error; pwEvent("soundcloud_stream_failed", details: candidateTrace.merging(PWDownloadLog.error(error)) { _, new in new })
                    // Return a refused stream to the common two-attempt policy;
                    // do not hide it behind more candidate or provider attempts.
                    if (error as? PWAudioHTTPError)?.status == 403 { throw error }
                }
            }
        }
        throw last
    }
    private func transfer(_ url: URL, segment: Bool = false, trace: [String: Any], progress: @escaping @MainActor (String) -> Void) async throws -> URL {
        let transfer = PWAudioTransfer(minimumBytes: segment ? 0 : 1024, allowed: { PWSoundCloudRules.mediaURL($0) }, report: { event, status, details in
            pwEvent("soundcloud_" + event, status, details: trace.merging(details) { _, new in new })
        }, progress: { bytes, total in Task { @MainActor in
            progress(total > 0 ? "SoundCloud : \(Int(Double(bytes) * 100 / Double(total))) %" : "SoundCloud : \(bytes / 1024) Ko")
        } })
        return try await transfer.download(url)
    }
    private func hls(_ url: URL, session: URLSession, duration: Double, trace: [String: Any], progress: @escaping @MainActor (String) -> Void) async throws -> URL {
        let bytes = try await data(url, session: session, stage: "playlist", trace: trace, maximum: 1024 * 1024)
        guard let text = String(data: bytes, encoding: .utf8), let segments = PWSoundCloudRules.segments(text, base: url, expectedDuration: duration) else {
            throw pwError("SoundCloud : flux incomplet, chiffré ou format HLS incompatible. Aucun fichier enregistré.")
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp3")
        guard FileManager.default.createFile(atPath: file.path, contents: nil) else { throw pwError("Impossible de préparer le fichier SoundCloud.") }
        var success = false
        defer { if !success { try? FileManager.default.removeItem(at: file) } }
        let handle = try FileHandle(forWritingTo: file); defer { try? handle.close() }
        let deadline = Date().addingTimeInterval(240); var total: Int64 = 0
        for (index, segment) in segments.enumerated() {
            try Task.checkCancellation()
            guard Date() < deadline else { throw URLError(.timedOut) }
            progress("SoundCloud : fragment \(index + 1)/\(segments.count)…")
            let raw = try await transfer(segment, segment: true, trace: trace.merging(["segment": index + 1, "segments": segments.count]) { _, new in new }, progress: { _ in })
            defer { try? FileManager.default.removeItem(at: raw) }
            let data = try Data(contentsOf: raw)
            total += Int64(data.count)
            guard total <= PWAudioTransfer.maximumBytes else { throw pwError("SoundCloud : fichier trop volumineux (128 Mo).") }
            try handle.write(contentsOf: data)
        }
        try handle.close(); success = true; return file
    }
}

enum PWSoundCloudAudio {
    static func convert(_ raw: URL, duration expected: Double) async throws -> URL {
        let probe = raw.deletingPathExtension().appendingPathExtension("mp3")
        if raw != probe { try FileManager.default.moveItem(at: raw, to: probe) }
        defer { try? FileManager.default.removeItem(at: probe) }
        let asset = AVURLAsset(url: probe, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, abs(duration - expected) <= max(8, expected * 0.05),
              !(try await asset.loadTracks(withMediaType: .audio)).isEmpty,
              let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw pwError("SoundCloud : fichier ou durée incompatible avec le titre demandé.")
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
        guard export.status == .completed else { throw export.error ?? pwError("Conversion SoundCloud interrompue.") }
        let output = AVURLAsset(url: result), actual = try await output.load(.duration).seconds
        guard actual.isFinite, abs(actual - duration) < 0.25,
              !(try await output.loadTracks(withMediaType: .audio)).isEmpty else { throw pwError("Fichier SoundCloud incomplet.") }
        success = true; return result
    }
}
