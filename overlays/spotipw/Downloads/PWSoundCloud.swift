import Foundation
import Security
import AVFoundation

// Personal API access token, entered by the user. Never bundle an application
// secret or reuse cookies/client IDs from another SoundCloud application.
enum PWSoundCloudAccess {
    private static var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "PWDownloadProviders", kSecAttrAccount as String: "soundcloud"] }
    static var token: String? {
        var q = query; q[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func save(_ token: String) -> Bool {
        let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.contains("\n"), !value.contains("\r") else { return false }
        if value.isEmpty { let status = SecItemDelete(query as CFDictionary); return status == errSecSuccess || status == errSecItemNotFound }
        let attributes: [String: Any] = [kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound { return SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil) == errSecSuccess }
        return status == errSecSuccess
    }
}
final class PWSoundCloud: NSObject, URLSessionTaskDelegate {
    static let shared = PWSoundCloud()
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // Searches must stay on the API. No OAuth header leaves this origin.
        completionHandler(request.url?.host == "api.soundcloud.com" && request.url?.scheme == "https" ? request : nil)
    }
    static func mediaURL(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        return url.scheme == "https" && url.user == nil && url.password == nil &&
            (host == "api.soundcloud.com" || host.hasSuffix(".sndcdn.com"))
    }
    func download(_ track: PWAudioTrack, trace: [String: Any], progress: @escaping @MainActor (String) -> Void) async throws -> URL {
        guard let token = PWSoundCloudAccess.token, !token.isEmpty else {
            throw PWDownloadError(message: "Configure un jeton API SoundCloud dans Téléchargements → Accès SoundCloud. Aucun jeton n’est fourni avec l’application.", pausesQueue: true)
        }
        await progress("Recherche SoundCloud…")
        var components = URLComponents(string: "https://api.soundcloud.com/tracks")!
        components.queryItems = [URLQueryItem(name: "q", value: track.title + " " + track.artist),
            URLQueryItem(name: "limit", value: "50"), URLQueryItem(name: "linked_partitioning", value: "true")]
        var request = URLRequest(url: components.url!); request.setValue("OAuth " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let config = URLSessionConfiguration.ephemeral; config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 20; config.timeoutIntervalForResource = 30
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (stream, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw pwError("Réponse SoundCloud invalide.") }
        pwEvent("soundcloud_search_http", http.statusCode, details: trace)
        if http.statusCode == 401 { throw PWDownloadError(message: "Jeton API SoundCloud expiré ou invalide. Remplace-le dans Accès SoundCloud (les jetons expirent généralement après une heure).", pausesQueue: true) }
        if http.statusCode == 429 { throw PWDownloadError(message: "SoundCloud limite les demandes (HTTP 429). Réessaie plus tard.", pausesQueue: true) }
        guard http.statusCode == 200 else { throw pwError("Recherche SoundCloud refusée : HTTP \(http.statusCode).") }
        var bytes = Data()
        for try await byte in stream { guard bytes.count < 4 * 1024 * 1024 else { throw pwError("Réponse SoundCloud trop volumineuse.") }; bytes.append(byte) }
        let object = try JSONSerialization.jsonObject(with: bytes)
        let rows = (object as? [String: Any])?["collection"] as? [[String: Any]] ?? object as? [[String: Any]] ?? []
        var matches: [(URL, Double)] = []
        for row in rows {
            let artist = row["metadata_artist"] as? String ?? (row["user"] as? [String: Any])?["username"] as? String ?? ""
            let candidate = PWAudioCandidate(id: "", title: row["title"] as? String ?? "", artist: artist, duration: (row["duration"] as? Double ?? 0) / 1000)
            let reason = PWDownloadRules.rejection(candidate, for: track, requireYouTubeID: false)
            let downloadable = row["downloadable"] as? Bool == true
            pwEvent("soundcloud_candidate", details: trace.merging(["candidate_title": candidate.title, "candidate_artist": artist,
                "candidate_duration": candidate.duration, "rejection": reason ?? (downloadable ? "accepted" : "download_not_enabled")]) { _, new in new })
            guard reason == nil, downloadable, let text = row["download_url"] as? String,
                  let url = URL(string: text), url.host == "api.soundcloud.com", Self.mediaURL(url) else { continue }
            matches.append((url, abs(candidate.duration - track.duration)))
        }
        guard let url = matches.sorted(by: { $0.1 < $1.1 }).first?.0 else {
            throw pwError("SoundCloud : aucune correspondance sûre avec téléchargement autorisé parmi \(rows.count) résultats. Les pistes limitées à l’écoute ne sont pas exportées.")
        }
        await progress("Téléchargement SoundCloud…")
        let transfer = PWAudioTransfer(allowed: { Self.mediaURL($0) }, report: { event, code, details in
            pwEvent("soundcloud_" + event, code, details: trace.merging(details) { _, new in new })
        }, progress: { bytes, total in Task { @MainActor in
            progress(total > 0 ? "SoundCloud : \(Int(Double(bytes) * 100 / Double(total))) %" : "SoundCloud : \(bytes / 1024) Ko")
        } })
        let raw = try await transfer.download(url, soundCloudToken: token)
        defer { try? FileManager.default.removeItem(at: raw) }
        try Task.checkCancellation()
        await progress("Préparation du fichier SoundCloud…")
        // Creator-enabled originals can be MP3/WAV/etc. Convert using iOS's
        // supported audio exporter, then check duration before accepting a file.
        let asset = AVURLAsset(url: raw, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, abs(duration - track.duration) <= max(8, track.duration * 0.05) else { throw pwError("Le fichier SoundCloud ne correspond pas à la durée attendue.") }
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else { throw pwError("Format SoundCloud non pris en charge par iOS.") }
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
        let output = AVURLAsset(url: result)
        let actual = try await output.load(.duration).seconds
        guard actual.isFinite, abs(actual - duration) < 0.25 else { throw pwError("Fichier SoundCloud incomplet après conversion.") }
        success = true; return result
    }
}
