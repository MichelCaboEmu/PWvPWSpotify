import Foundation
import UIKit
import UniformTypeIdentifiers
import AVFoundation

let pwSourceKey = "spotifyglass.download.source"
let pwFolderKey = "spotifyglass.download.folder"
let pwChanged = Notification.Name("PWDownloadsChanged")
func pwEvent(_ event: String, _ code: Int = 0, details: [String: Any] = [:]) {
    NotificationCenter.default.post(name: Notification.Name("PWDownloadDiagnostic"), object: nil,
                                    userInfo: ["event": event, "code": code, "details": PWDownloadLog.fields(details)])
}
struct PWDownloadError: LocalizedError {
    let message: String
    var pausesQueue = false
    var fallbackEligible = false
    var errorDescription: String? { message }
}
func pwError(_ message: String) -> PWDownloadError { PWDownloadError(message: message) }

extension Bundle {
    static var pwYouTubeKit: Bundle {
        Bundle.main.url(forResource: "PWYouTubeKit", withExtension: "bundle").flatMap(Bundle.init(url:)) ?? .main
    }
}

// Separate sessions ensure the Spotify bearer never reaches the audio/search provider.
final class PWDownloadHTTP: NSObject, URLSessionTaskDelegate {
    private let host: String?
    init(host: String?) { self.host = host }
    lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 25
        config.timeoutIntervalForResource = 240
        config.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, PWYouTubeAccess.redirectAllowed(originHost: host, to: url) else {
            let consent = request.url.map(PWYouTubeAccess.consentURL) == true
            pwEvent(consent ? "youtube_consent_redirect" : "redirect_refused", response.statusCode)
            completionHandler(nil); return
        }
        var redirected = request
        if let host = host, PWYouTubeAccess.publicHost(host) {
            redirected.setValue(nil, forHTTPHeaderField: "Authorization")
            PWYouTubeAccess.apply(to: &redirected)
        }
        pwEvent("redirect_followed", response.statusCode)
        completionHandler(redirected)
    }
    func data(_ request: URLRequest, stage: PWDownloadStage, maximum: Int = 12 * 1024 * 1024) async throws -> Data {
        let data: Data, response: URLResponse
        let started = Date()
        var prepared = request
        if let host = host, PWYouTubeAccess.publicHost(host) {
            prepared.setValue(PWYouTubeAccess.userAgent, forHTTPHeaderField: "User-Agent")
            PWYouTubeAccess.apply(to: &prepared)
        }
        try Task.checkCancellation()
        pwEvent(stage.rawValue + "_started")
        do { (data, response) = try await session.data(for: prepared) }
        catch { pwEvent(stage.rawValue + "_network", (error as NSError).code, details: PWDownloadLog.error(error).merging(["elapsed_ms": Int(Date().timeIntervalSince(started) * 1000)]) { _, new in new }); throw error }
        guard let http = response as? HTTPURLResponse else { throw pwError("Réponse réseau invalide.") }
        var details: [String: Any] = ["elapsed_ms": Int(Date().timeIntervalSince(started) * 1000),
            "bytes": data.count, "content_type": http.mimeType ?? "unknown"]
        if http.statusCode != 200, data.count < maximum,
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let providerError = object["error"] as? [String: Any] {
            details["provider_message"] = providerError["message"] as? String
            details["provider_code"] = providerError["code"] as? Int
        }
        pwEvent(stage.rawValue + "_http", http.statusCode, details: details)
        guard http.statusCode == 200 else {
            if (300...399).contains(http.statusCode), !stage.spotify,
               let location = http.value(forHTTPHeaderField: "Location"),
               let target = URL(string: location, relativeTo: http.url)?.absoluteURL,
               PWYouTubeAccess.consentURL(target) {
                let headers = http.allHeaderFields.reduce(into: [String: String]()) { result, entry in
                    if let name = entry.key as? String, let value = entry.value as? String { result[name] = value }
                }
                let cookies = http.url.map { PWYouTubeAccess.consentState(headers: headers, from: $0) } ?? []
                throw PWYouTubeConsentRequired(source: stage.rawValue.hasPrefix("youtube_music") ? 0 : 1,
                                               target: target, cookies: cookies)
            }
            throw PWDownloadHTTPError(stage: stage, status: http.statusCode)
        }
        guard data.count < maximum else { throw pwError("La réponse du fournisseur est trop grande.") }
        return data
    }
    func json(_ request: URLRequest, stage: PWDownloadStage) async throws -> [String: Any] {
        let bytes = try await data(request, stage: stage)
        let object: [String: Any]
        do {
            guard let parsed = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
                throw pwError("La réponse JSON du fournisseur n’est pas un objet.")
            }
            object = parsed
        } catch {
            pwEvent(stage.rawValue + "_invalid_json", details: PWDownloadLog.error(error))
            throw error
        }
        if let providerError = object["error"] as? [String: Any] {
            let message = PWDownloadLog.clean(providerError["message"] as? String ?? "Erreur sans message")
            let code = providerError["code"] as? Int ?? 0
            pwEvent(stage.rawValue + "_provider_error", code, details: ["provider_message": message])
            throw PWDownloadError(message: "Erreur fournisseur (\(stage.rawValue), code \(code)) : \(message)", pausesQueue: true)
        }
        return object
    }

}

struct PWDownloadItem: Codable {
    var track: PWAudioTrack
    var state = "pending"
    var file: String?
    var error: String?
    var phase: String?
}
struct PWDownloadJob: Codable {
    var id = UUID().uuidString
    var uri: String
    var title: String
    var source: Int
    var folder: Data?
    var items: [PWDownloadItem]
    var skipped: Int
    var paused = false
    var lastError: String?
    var notice: String?
}

actor PWDownloadFiles {
    static let shared = PWDownloadFiles()
    static func root(for job: PWDownloadJob) throws -> URL {
        if let bookmark = job.folder {
            var stale = false
            let url = try URL(resolvingBookmarkData: bookmark, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
            guard !stale else { throw pwError("Choisis à nouveau le dossier dans les paramètres : son autorisation a expiré.") }
            return url
        }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Spotify Downloads", isDirectory: true)
    }
    func save(_ temporary: URL, track: PWAudioTrack, job: PWDownloadJob) throws -> String {
        try Task.checkCancellation()
        let root = try Self.root(for: job)
        let scoped = root.startAccessingSecurityScopedResource()
        defer { if scoped { root.stopAccessingSecurityScopedResource() } }
        // A URL inside our container needs no security scope. The coordinated write
        // below is the authority on access; false alone is not a write failure.
        let folder = root.appendingPathComponent("Playlist-" + job.id, isDirectory: true)
        var coordinationError: NSError?, operationError: Error?, name: String?
        NSFileCoordinator().coordinate(writingItemAt: folder, options: .forMerging, error: &coordinationError) { granted in
            do {
                try FileManager.default.createDirectory(at: granted, withIntermediateDirectories: true)
                var filename = PWDownloadRules.filename(track)
                // A file placed here by the user is never overwritten.
                if FileManager.default.fileExists(atPath: granted.appendingPathComponent(filename).path) {
                    let base = String(filename.dropLast(4))
                    var suffix = 2
                    while FileManager.default.fileExists(atPath: granted.appendingPathComponent(base + " (\(suffix)).m4a").path) { suffix += 1 }
                    filename = base + " (\(suffix)).m4a"
                }
                let destination = granted.appendingPathComponent(filename)
                try Task.checkCancellation()
                try FileManager.default.copyItem(at: temporary, to: destination)
                name = filename
            } catch { operationError = error }
        }
        if let error = operationError ?? coordinationError { throw error }
        guard let name = name else { throw pwError("Le fournisseur de fichiers n’a pas enregistré le morceau.") }
        return name
    }
}

@MainActor
final class PWDownloadStore {
    static let shared = PWDownloadStore()
    var jobs: [PWDownloadJob] = []
    var importing = false
    var importError: String?
    var selectedPlaylist: String?
    var availableImport: (uri: String, title: String, native: PWNativePlaylist)?
    var consentRequest: PWYouTubeConsentRequired?
    var consentSource: Int? { consentRequest?.source }
    private var consentJobIDs = Set<String>()
    private var worker: Task<Void, Never>?
    private var importer: Task<Void, Never>?
    private var importGeneration = UUID()
    private var activeID: String?
    private var background = UIBackgroundTaskIdentifier.invalid
    private let spotify = PWDownloadHTTP(host: "api.spotify.com")
    private let music = PWDownloadHTTP(host: "music.youtube.com")
    private let youtube = PWDownloadHTTP(host: "www.youtube.com")
    private var searchConfigs: [Int: (Date, PWYouTubeSearchConfig)] = [:]
    private var stateURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PWDownloads", isDirectory: true).appendingPathComponent("queue.json")
    }
    private init() {
        if let data = try? Data(contentsOf: stateURL), data.count < 24 * 1024 * 1024,
           let saved = try? JSONDecoder().decode([PWDownloadJob].self, from: data) {
            jobs = Array(saved.prefix(50))
            for j in jobs.indices {
                jobs[j].paused = true
                for i in jobs[j].items.indices where jobs[j].items[i].state == "working" { jobs[j].items[i].state = "pending" }
            }
        }
        PWLocalLibrary.shared.migrate(jobs)
    }
    func changed() {
        do {
            try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(jobs).write(to: stateURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch { pwEvent("queue_save_failed", (error as NSError).code, details: PWDownloadLog.error(error)) }
        NotificationCenter.default.post(name: pwChanged, object: nil)
    }
    private func cancelImport() {
        importGeneration = UUID(); importer?.cancel(); importer = nil; importing = false
    }
    func importPlaylist(uri: String, title: String, authorization: String, native: PWNativePlaylist? = nil) {
        // A new arrow press selects this playlist even when its import fails.
        // Old work must not continue invisibly beneath the new error message.
        cancelImport(); availableImport = nil; importError = nil; selectedPlaylist = title
        for j in jobs.indices where jobs[j].uri != uri {
            jobs[j].paused = true; consentJobIDs.remove(jobs[j].id)
        }
        if let active = activeID, jobs.first(where: { $0.id == active })?.uri != uri { worker?.cancel() }
        if consentJobIDs.isEmpty { consentRequest = nil }
        pwEvent("playlist_selected", details: ["playlist": title, "queued_playlists": jobs.count])
        changed()
        // Re-read the current snapshot on every press, including existing jobs.
        // The global file catalog decides which tracks need a transfer.
        if let j = jobs.firstIndex(where: { $0.uri == uri }) {
            jobs[j].paused = true
            if activeID == jobs[j].id { worker?.cancel() }
        } else if jobs.count >= 50 {
            importError = "La file contient 50 playlists. Retire une ancienne playlist de la liste."; changed(); return
        }
        guard let path = PWDownloadRules.playlistPath(uri) else { importError = "Cette page n’est pas une playlist compatible."; changed(); return }
        if let native = native, native.complete {
            enqueueNative(uri: uri, title: title, native: native); return
        }
        // A verified displayed snapshot is useful even if Spotify's announced
        // total differs. Never label it complete or hit three known-failing APIs.
        if let native = native, !native.tracks.isEmpty {
            availableImport = (uri, title, native)
            importError = native.problem
            pwEvent("playlist_available_choice", native.tracks.count, details: ["playlist": title,
                "loaded_rows": native.availableRows, "announced_rows": native.total])
            changed(); return
        }
        pwEvent(native == nil ? "playlist_native_unavailable" : "playlist_native_incomplete", native?.total ?? 0)
        guard authorization.hasPrefix("Bearer ") else { importError = "Lance une chanson pour initialiser la session Spotify, puis réessaie la flèche."; changed(); return }
        importing = true; importError = nil; changed()
        let source = UserDefaults.standard.integer(forKey: pwSourceKey)
        let folder = UserDefaults.standard.data(forKey: pwFolderKey)
        let generation = importGeneration
        importer = Task {
            defer { if importGeneration == generation { importing = false; importer = nil; changed() } }
            do {
                var tracks: [PWAudioTrack] = [], read = 0, total: Int?, offset = 0
                var endpoint = path, triedDocument = false
                while true {
                    try Task.checkCancellation()
                    var request = URLRequest(url: URL(string: "https://api.spotify.com\(endpoint)?limit=50&offset=\(offset)")!)
                    request.setValue(authorization, forHTTPHeaderField: "Authorization")
                    var page: [String: Any]
                    let stage: PWDownloadStage = endpoint == "/v1/me/tracks" ? .spotifySaved : endpoint.hasSuffix("/items") ? .spotifyItems : .spotifyTracks
                    do { page = try await spotify.json(request, stage: stage) }
                    catch let error as PWDownloadHTTPError where error.status == 404 && error.stage.spotify {
                        // Support both documented API generations; never retry an access denial.
                        if endpoint.hasSuffix("/items"), !triedDocument {
                            endpoint = String(endpoint.dropLast(6)) + "/tracks"
                            pwEvent("spotify_try_legacy_items"); continue
                        }
                        guard offset == 0, endpoint.hasPrefix("/v1/playlists/"), !triedDocument else { throw error }
                        triedDocument = true
                        let rootPath = String(endpoint.dropLast(7))
                        var rootRequest = URLRequest(url: URL(string: "https://api.spotify.com" + rootPath)!)
                        rootRequest.setValue(authorization, forHTTPHeaderField: "Authorization")
                        let document = try await spotify.json(rootRequest, stage: .spotifyDocument)
                        if let embedded = document["items"] as? [String: Any] {
                            page = embedded; endpoint = rootPath + "/items"
                        } else if let embedded = document["tracks"] as? [String: Any] {
                            page = embedded; endpoint = rootPath + "/tracks"
                        } else {
                            pwEvent("spotify_items_not_exposed")
                            throw pwError("Spotify n’expose pas les morceaux de cette playlist à cette session. La recherche YouTube n’a pas démarré.")
                        }
                        pwEvent("spotify_embedded_items")
                    }
                    guard let items = page["items"] as? [[String: Any]], let reported = page["total"] as? Int,
                          reported >= 0, reported <= 10000 else { throw pwError("La liste des morceaux est incomplète ou dépasse 10 000 titres.") }
                    if let total = total, total != reported { throw pwError("La playlist a changé pendant son chargement. Réessaie.") }
                    total = reported
                    tracks += PWDownloadRules.tracks(items); read += items.count
                    if read >= reported { break }
                    guard !items.isEmpty else { throw pwError("Spotify n’a renvoyé qu’une partie de la playlist. Aucun téléchargement n’a démarré.") }
                    offset += items.count
                }
                guard !tracks.isEmpty else { throw pwError("Aucun morceau audio pris en charge dans cette playlist.") }
                var seen = Set<String>()
                let unique = tracks.filter { seen.insert($0.id).inserted }
                try Task.checkCancellation()
                guard importGeneration == generation else { return }
                enqueue(PWDownloadJob(uri: uri, title: title, source: source == 3 ? 3 : min(source, 1), folder: folder,
                                          items: unique.map { PWDownloadItem(track: $0) }, skipped: read - unique.count), complete: true)
                pwEvent("playlist_queued", unique.count); changed(); start()
            } catch {
                guard importGeneration == generation, !Task.isCancelled else { return }
                if let http = error as? PWDownloadHTTPError, http.status == 404, let problem = native?.problem {
                    importError = problem + " L’API Spotify renvoie aussi HTTP 404."
                } else { importError = error.localizedDescription }
                pwEvent("playlist_failed", (error as NSError).code, details: PWDownloadLog.error(error).merging(["playlist": title, "message": importError ?? error.localizedDescription]) { _, new in new })
            }
        }
    }
    private func enqueueNative(uri: String, title: String, native: PWNativePlaylist) {
        var seen = Set<String>()
        let unique = native.tracks.filter { seen.insert($0.id).inserted }
        guard !unique.isEmpty else { importError = "Aucun morceau audio pris en charge dans cette playlist."; changed(); return }
        let missing = max(0, native.total - native.availableRows)
        var job = PWDownloadJob(uri: uri, title: title, source: Self.selectedSource,
            folder: UserDefaults.standard.data(forKey: pwFolderKey), items: unique.map { PWDownloadItem(track: $0) },
            skipped: max(0, native.availableRows - unique.count))
        if !native.complete { job.notice = "Liste partielle choisie : \(native.availableRows) éléments chargés sur \(native.total) annoncés ; \(missing) absents du téléchargement." }
        enqueue(job, complete: native.complete); availableImport = nil; importError = nil
        pwEvent(native.complete ? "playlist_native_loaded" : "playlist_available_confirmed", native.availableRows,
                details: ["playlist": title, "announced_rows": native.total, "missing_rows": missing])
        pwEvent("playlist_queued", unique.count); changed(); start()
    }
    static var selectedSource: Int {
        let source = UserDefaults.standard.integer(forKey: pwSourceKey)
        return source == 3 ? 3 : min(source, 1)
    }
    func enqueue(_ proposed: PWDownloadJob, complete: Bool) {
        var job = proposed
        if let index = jobs.firstIndex(where: { $0.uri == job.uri }) {
            let old = jobs[index]
            job.id = old.id; job.folder = old.folder
            if !complete {
                let incoming = Set(job.items.map { $0.track.id })
                job.items += old.items.filter { !incoming.contains($0.track.id) }
            }
            jobs.remove(at: index)
        }
        for i in job.items.indices {
            if let saved = PWLocalLibrary.shared.available(job.items[i].track.id) {
                job.items[i].state = "done"; job.items[i].file = saved.filename
            }
        }
        PWLocalLibrary.shared.rememberPlaylist(uri: job.uri, title: job.title, tracks: job.items.map(\.track), complete: complete)
        jobs.append(job)
        pwEvent("playlist_incremental", details: ["playlist": job.title,
            "already_saved": job.items.filter { $0.state == "done" }.count,
            "to_download": job.items.filter { $0.state == "pending" }.count])
    }
    func downloadTrack(_ track: PWAudioTrack, source: Int) {
        pauseAll()
        selectedPlaylist = track.title; importError = nil
        enqueue(PWDownloadJob(uri: "spotify:track:" + track.id, title: track.title, source: source,
            folder: UserDefaults.standard.data(forKey: pwFolderKey), items: [PWDownloadItem(track: track)], skipped: 0), complete: true)
        changed(); start()
    }
    func resumeAll() {
        for id in jobs.map(\.id) { resume(id) }
    }
    func downloadAvailable() {
        guard let choice = availableImport else { return }
        enqueueNative(uri: choice.uri, title: choice.title, native: choice.native)
    }
    func pauseAll() {
        cancelImport(); availableImport = nil; consentJobIDs.removeAll(); consentRequest = nil
        for j in jobs.indices { jobs[j].paused = true }
        worker?.cancel(); changed()
    }
    func clearQueue() {
        pauseAll()
        let count = jobs.count
        jobs.removeAll(); importError = nil; selectedPlaylist = nil; searchConfigs.removeAll()
        pwEvent("queue_cleared", count); changed()
    }
    func resume(_ id: String) {
        guard let j = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[j].paused = false; jobs[j].lastError = nil
        for i in jobs[j].items.indices {
            if let saved = PWLocalLibrary.shared.available(jobs[j].items[i].track.id) {
                jobs[j].items[i].state = "done"; jobs[j].items[i].file = saved.filename; jobs[j].items[i].error = nil
            } else if jobs[j].items[i].state != "working" {
                jobs[j].items[i].state = "pending"; jobs[j].items[i].error = nil
            }
        }
        changed(); start()
    }
    func consentCompleted() {
        let ids = consentJobIDs
        consentJobIDs.removeAll(); consentRequest = nil; searchConfigs.removeAll()
        pwEvent("youtube_access_resumed")
        for id in ids { resume(id) }
        changed()
    }
    func remove(_ id: String) {
        if activeID == id { worker?.cancel() }
        jobs.removeAll { $0.id == id }; consentJobIDs.remove(id)
        if consentJobIDs.isEmpty { consentRequest = nil }
        pwEvent("playlist_removed", details: ["job": id]); changed()
    }
    private func start() {
        guard worker == nil else { return }
        worker = Task {
            defer {
                worker = nil; activeID = nil; changed(); endBackground()
                if jobs.contains(where: { !$0.paused && $0.items.contains(where: { $0.state == "pending" }) }) { start() }
            }
            background = UIApplication.shared.beginBackgroundTask(withName: "Playlist audio") { [weak self] in
                Task { @MainActor in self?.pauseAll(); self?.endBackground(); pwEvent("background_expired") }
            }
            while !Task.isCancelled {
                guard let j = jobs.firstIndex(where: { !$0.paused && $0.items.contains(where: { $0.state == "pending" }) }),
                      let i = jobs[j].items.firstIndex(where: { $0.state == "pending" }) else { break }
                let job = jobs[j], track = job.items[i].track
                if let saved = PWLocalLibrary.shared.available(track.id) {
                    update(job.id, track.id, state: "done", file: saved.filename)
                    pwEvent("audio_already_saved", details: ["title": track.title]); continue
                }
                let started = Date()
                let trace: [String: Any] = ["job": job.id, "playlist": job.title, "item": i + 1,
                    "title": track.title, "artist": track.artist, "duration": track.duration,
                    "source": pwSourceName(job.source)]
                activeID = job.id; jobs[j].items[i].state = "working"; jobs[j].items[i].phase = "Recherche…"; changed()
                pwEvent("audio_started", details: trace)
                do {
                    let temporary = try await fetchWithFallback(track, source: job.source, trace: trace) { phase in
                        guard let j = self.jobs.firstIndex(where: { $0.id == job.id }),
                              let i = self.jobs[j].items.firstIndex(where: { $0.track.id == track.id }),
                              self.jobs[j].items[i].state == "working" else { return }
                        self.jobs[j].items[i].phase = phase; self.changed()
                    }
                    defer { try? FileManager.default.removeItem(at: temporary) }
                    try Task.checkCancellation()
                    pwEvent("audio_saving", details: trace)
                    let file = try await PWDownloadFiles.shared.save(temporary, track: track, job: job)
                    PWLocalLibrary.shared.record(track: track, job: job, filename: file)
                    update(job.id, track.id, state: "done", file: file)
                    pwEvent("audio_saved", details: trace.merging(["elapsed_ms": Int(Date().timeIntervalSince(started) * 1000)]) { _, new in new })
                } catch {
                    let cancelled = Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled
                    update(job.id, track.id, state: cancelled ? "pending" : "failed", error: cancelled ? nil : error.localizedDescription)
                    pwEvent(cancelled ? "audio_paused" : "audio_failed", (error as NSError).code, details: trace.merging(PWDownloadLog.error(error)) { _, new in new }.merging(["elapsed_ms": Int(Date().timeIntervalSince(started) * 1000)]) { _, new in new })
                    if cancelled { break }
                    if let consent = error as? PWYouTubeConsentRequired {
                        consentRequest = consent
                        // Resume only the jobs affected by this consent pause.
                        for index in jobs.indices where !jobs[index].paused {
                            consentJobIDs.insert(jobs[index].id)
                            jobs[index].paused = true; jobs[index].lastError = consent.localizedDescription
                        }
                        pwEvent("youtube_consent_required", consent.source); changed(); break
                    }
                    if (error as? PWDownloadError)?.pausesQueue == true || error is PWDownloadHTTPError {
                        for index in jobs.indices {
                            jobs[index].paused = true
                            jobs[index].lastError = error.localizedDescription
                        }
                        changed()
                        break
                    }
                }
            }
        }
    }
    private func endBackground() {
        if background != .invalid { UIApplication.shared.endBackgroundTask(background); background = .invalid }
    }
    private func update(_ jobID: String, _ trackID: String, state: String, file: String? = nil, error: String? = nil) {
        guard let j = jobs.firstIndex(where: { $0.id == jobID }), let i = jobs[j].items.firstIndex(where: { $0.track.id == trackID }) else { return }
        jobs[j].items[i].state = state; jobs[j].items[i].file = file; jobs[j].items[i].error = error; changed()
    }
    private func fetchWithFallback(_ track: PWAudioTrack, source: Int, trace: [String: Any], progress: @escaping @MainActor (String) -> Void) async throws -> URL {
        let file: URL
        if source == 3 {
            file = try await PWSoundCloud.shared.download(track, trace: trace, progress: progress)
        } else {
            do { file = try await fetchAudio(track, source: source, trace: trace, progress: progress) }
            catch {
                try Task.checkCancellation()
                // Fallback for a missing match or a refused media stream, never
                // for consent, quota, authentication or a cancelled task.
                let missingMatch = (error as? PWDownloadError)?.fallbackEligible == true
                let refusedMedia = (error as? PWAudioHTTPError).map { [403, 410].contains($0.status) } == true
                guard missingMatch || refusedMedia,
                      UserDefaults.standard.bool(forKey: "spotifyglass.download.soundcloudFallback") else { throw error }
                guard PWSoundCloudAccess.token != nil else {
                    throw pwError(error.localizedDescription + " Secours SoundCloud non configuré : ajoute un jeton API dans les paramètres.")
                }
                pwEvent("soundcloud_fallback_started", details: trace.merging(PWDownloadLog.error(error)) { _, new in new })
                do { file = try await PWSoundCloud.shared.download(track, trace: trace, progress: progress) }
                catch let fallback {
                    throw PWDownloadError(message: error.localizedDescription + "\nSecours SoundCloud : " + fallback.localizedDescription,
                        pausesQueue: (fallback as? PWDownloadError)?.pausesQueue ?? false)
                }
            }
        }
        // Basic tags are always written. External enrichment is explicit and
        // updates the whole local catalog through the metadata button.
        do {
            let tagged = try await PWMetadata.tag(file, track: track, match: nil)
            try? FileManager.default.removeItem(at: file); return tagged
        } catch {
            if Task.isCancelled { try? FileManager.default.removeItem(at: file); throw error }
            pwEvent("basic_metadata_failed", details: PWDownloadLog.error(error)); return file
        }
    }
    private func fetchAudio(_ track: PWAudioTrack, source: Int, trace: [String: Any], progress: @escaping @MainActor (String) -> Void) async throws -> URL {
        try Task.checkCancellation()
        let isMusic = source == 0
        let host = isMusic ? "music.youtube.com" : "www.youtube.com"
        var request = URLRequest(url: URL(string: "https://\(host)/youtubei/v1/search")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let client = isMusic ? music : youtube
        let configuration: PWYouTubeSearchConfig
        if let cached = searchConfigs[source], Date().timeIntervalSince(cached.0) < 3600 {
            configuration = cached.1
        } else {
            let page = try await client.data(URLRequest(url: URL(string: "https://\(host)/")!),
                                             stage: isMusic ? .youtubeMusicConfig : .youtubeConfig, maximum: 4 * 1024 * 1024)
            guard let html = String(data: page, encoding: .utf8), let config = PWYouTubeSearchConfig.parse(html, music: isMusic) else {
                pwEvent(isMusic ? "youtube_music_config_missing" : "youtube_config_missing")
                throw PWDownloadError(message: "La configuration publique de YouTube est indisponible. La file est en pause ; exporte les logs pour le diagnostic.", pausesQueue: true)
            }
            searchConfigs[source] = (Date(), config); configuration = config
        }
        request.setValue(configuration.clientNumber, forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(configuration.version, forHTTPHeaderField: "X-YouTube-Client-Version")
        request.setValue("https://\(host)", forHTTPHeaderField: "Origin")
        var chosen: PWAudioCandidate?
        var allResults = Set<String>()
        var rejections: [String: Int] = [:]
        let plan = PWSearchAttempt.plan(track, music: isMusic)
        for (index, attempt) in plan.enumerated() {
            try Task.checkCancellation()
            progress("Recherche \(index + 1)/\(plan.count)…")
            let searchTrace = trace.merging(["query": attempt.query, "search_mode": attempt.mode, "search_attempt": index + 1]) { _, new in new }
            pwEvent("search_request", details: searchTrace)
            var body: [String: Any] = ["query": attempt.query, "context": configuration.context]
            if let params = attempt.params { body["params"] = params }
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let json: [String: Any]
            do { json = try await client.json(request, stage: isMusic ? .youtubeMusicSearch : .youtubeSearch) }
            catch { searchConfigs.removeValue(forKey: source); throw error }
            try Task.checkCancellation()
            let parsed = PWDownloadRules.candidates(json, music: isMusic)
            var counts: [String: Any] = ["candidates": parsed.count, "renderers": PWDownloadRules.rendererCounts(json)]
            var rejected: [String: Int] = [:]
            for candidate in parsed {
                if let reason = PWDownloadRules.rejection(candidate, for: track) {
                    rejected[reason, default: 0] += 1
                    if allResults.insert(candidate.id).inserted { rejections[reason, default: 0] += 1 }
                }
            }
            for (reason, count) in rejected { counts["reject_" + reason] = count }
            let candidates = parsed.compactMap { candidate -> (PWAudioCandidate, Int)? in
                PWDownloadRules.score(candidate, for: track).map { (candidate, $0) }
            }.sorted { $0.1 > $1.1 }
            counts["accepted"] = candidates.count
            pwEvent("search_results", details: searchTrace.merging(counts) { _, new in new })
            for candidate in parsed.prefix(5) {
                pwEvent("search_candidate", details: searchTrace.merging(["candidate_title": candidate.title,
                    "candidate_artist": candidate.artist, "candidate_duration": candidate.duration,
                    "rejection": PWDownloadRules.rejection(candidate, for: track) ?? "accepted"]) { _, new in new })
            }
            if let candidate = candidates.first?.0 { chosen = candidate; break }
        }
        guard let candidate = chosen else {
            if allResults.isEmpty { throw PWDownloadError(message: "Aucun résultat audio reconnu après \(plan.count) recherches dans \(isMusic ? "YouTube Music" : "YouTube"). Essaie l’autre source. Les détails sont dans les logs.", fallbackEligible: true) }
            let labels = ["identifier": "identifiant invalide", "missing_duration": "durée absente",
                "duration": "durée différente", "title": "titre différent", "artist": "artiste différent", "version": "autre version"]
            let reasons = rejections.keys.sorted().map { "\(labels[$0] ?? $0) : \(rejections[$0]!)" }.joined(separator: ", ")
            throw PWDownloadError(message: "Aucune correspondance sûre parmi \(allResults.count) résultats distincts après \(plan.count) recherches pour « \(track.title) » — \(track.artist). Motifs : \(reasons). Essaie l’autre source ; les logs détaillent chaque recherche.", fallbackEligible: true)
        }
        progress("Extraction du flux audio…")
        pwEvent("extraction_started", details: trace.merging(["candidate_title": candidate.title, "candidate_artist": candidate.artist, "candidate_duration": candidate.duration]) { _, new in new })
        try Task.checkCancellation()
        // Explicitly local: YouTubeKit's optional remote service is never enabled.
        let video = YouTube(videoID: candidate.id, methods: [.local])
        let streams: [Stream]
        do { streams = try await video.streams }
        catch {
            try Task.checkCancellation()
            if (error as? URLError)?.code == .cancelled { throw error }
            let reason = (error as? YouTubeKitError)?.rawValue ?? PWDownloadLog.clean(error.localizedDescription)
            pwEvent("local_extraction_failed", (error as NSError).code, details: trace.merging(PWDownloadLog.error(error)) { _, new in new }.merging(["extractor_error": reason]) { _, new in new })
            throw PWDownloadError(message: "Extraction YouTube impossible : \(reason). La file est en pause ; les logs contiennent l’erreur d’origine.", pausesQueue: true)
        }
        try Task.checkCancellation()
        pwEvent("extraction_finished", streams.count, details: trace)
        progress("Téléchargement du fichier audio…")
        let compatible = streams.filterAudioOnly().filter { $0.fileExtension == .m4a && PWDownloadRules.mediaURL($0.url) }
        let ordered = compatible.enumerated().sorted {
            let left = $0.element.bitrate ?? 0, right = $1.element.bitrate ?? 0
            return left == right ? $0.offset < $1.offset : left > right
        }.map { $0.element }
        guard !ordered.isEmpty else { throw pwError("Aucun flux M4A compatible accessible sur cet iPhone.") }
        pwEvent("audio_download_started", details: trace.merging(["timeout_seconds": 120, "range_requested": true,
            "available_streams": ordered.count]) { _, new in new })
        let file: URL
        do {
            file = try await PWAudioTransfer.downloadAlternatives(ordered.map { $0.url }, report: { event, status, details in
                pwEvent(event, status, details: trace.merging(details) { _, new in new })
            }, progress: { bytes, expected in
                let text = expected > 0
                    ? String(format: "Téléchargement : %.0f %% (%.1f / %.1f Mo)", Double(bytes) * 100 / Double(expected), Double(bytes) / 1_000_000, Double(expected) / 1_000_000)
                    : String(format: "Téléchargement : %.1f Mo reçus", Double(bytes) / 1_000_000)
                Task { @MainActor in progress(text) }
            })
        } catch let error as URLError where error.code == .timedOut {
            throw PWDownloadError(message: "Le transfert audio a dépassé son délai (20 s sans données ou 120 s au total). La file est en pause. Les logs indiquent les octets reçus et la réponse du serveur.", pausesQueue: true)
        } catch let error as PWAudioHTTPError where error.status == 429 {
            throw PWDownloadError(message: "YouTube limite les transferts (HTTP 429). La file est en pause ; réessaie plus tard.", pausesQueue: true)
        }
        defer { try? FileManager.default.removeItem(at: file) }
        try Task.checkCancellation()
        progress("Préparation et vérification du fichier M4A…")
        do {
            return try await PWAudioContainer.normalize(file, expectedDuration: track.duration) { event, details in
                pwEvent(event, details: trace.merging(details) { _, new in new })
            }
        } catch {
            pwEvent("audio_container_failed", (error as NSError).code, details: trace.merging(PWDownloadLog.error(error)) { _, new in new })
            throw error
        }
    }
}

@MainActor
@objc(PWDownloadsBridge)
final class PWDownloadsBridge: NSObject, UIDocumentPickerDelegate {
    private static let pickerDelegate = PWDownloadsBridge()
    private weak var folderPresenter: UIViewController?
    @objc static var folderName: String { UserDefaults.standard.string(forKey: "spotifyglass.download.folderName") ?? "Sur mon iPhone / Spotify / Spotify Downloads" }
    @objc static var summary: String {
        let store = PWDownloadStore.shared
        if store.importing { return "Chargement de la playlist…" }
        let items = store.jobs.flatMap(\.items)
        return "\(items.filter { $0.state == "done" }.count)/\(items.count) enregistrés · \(items.filter { $0.state == "failed" }.count) erreurs"
    }
    @objc static func recordDiagnostics() {
        let store = PWDownloadStore.shared
        pwEvent("queue_snapshot", store.jobs.count, details: ["importing": store.importing,
            "import_error": store.importError ?? "", "selected_playlist": store.selectedPlaylist ?? "", "consent_required": store.consentSource != nil])
        for job in store.jobs {
            let trace: [String: Any] = ["job": job.id, "playlist": job.title, "paused": job.paused,
                "source": pwSourceName(job.source), "items": job.items.count,
                "pending": job.items.filter { $0.state == "pending" }.count,
                "done": job.items.filter { $0.state == "done" }.count,
                "failed": job.items.filter { $0.state == "failed" }.count,
                "last_error": job.lastError ?? ""]
            pwEvent("queue_job", details: trace)
            let active = job.items.filter { $0.state == "working" }
            let failures = job.items.filter { $0.state == "failed" }.suffix(3)
            for item in active + Array(failures) {
                pwEvent("queue_item", details: trace.merging(["title": item.track.title, "artist": item.track.artist,
                    "state": item.state, "phase": item.phase ?? "", "error_message": item.error ?? ""]) { _, new in new })
            }
        }
    }
    @objc(presentFrom:playlistURI:title:authorization:)
    static func present(from controller: UIViewController, playlistURI: String?, title: String?, authorization: String?) {
        present(from: controller, playlistURI: playlistURI, title: title, authorization: authorization, nativeModel: nil)
    }
    @objc(presentFrom:playlistURI:title:authorization:nativeModel:)
    static func present(from controller: UIViewController, playlistURI: String?, title: String?, authorization: String?, nativeModel: AnyObject?) {
        let vc = PWDownloadQueueController(style: .insetGrouped)
        if let uri = playlistURI {
            let native = nativeModel.flatMap { PWNativePlaylist.read(header: $0, requestedURI: uri, report: { pwEvent($0, $1, details: ["playlist": title ?? "Playlist"]) }) }
            PWDownloadStore.shared.importPlaylist(uri: uri, title: title ?? "Playlist", authorization: authorization ?? "", native: native)
        }
        let navigation = UINavigationController(rootViewController: vc)
        navigation.overrideUserInterfaceStyle = .dark
        controller.present(navigation, animated: true)
    }
    @objc(chooseFolderFrom:)
    static func chooseFolder(from controller: UIViewController) {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        guard controller.presentedViewController == nil else { pwEvent("folder_picker_busy"); return }
        pickerDelegate.folderPresenter = controller
        picker.delegate = pickerDelegate; picker.allowsMultipleSelection = false
        picker.modalPresentationStyle = .fullScreen
        picker.shouldShowFileExtensions = true
        picker.overrideUserInterfaceStyle = .dark
        let local = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Spotify Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        picker.directoryURL = local
        pwEvent("folder_picker_opened")
        controller.present(picker, animated: true)
    }
    @objc static func resetFolder() {
        UserDefaults.standard.removeObject(forKey: pwFolderKey)
        UserDefaults.standard.removeObject(forKey: "spotifyglass.download.folderName")
        PWDownloadStore.shared.changed(); pwEvent("folder_reset")
    }
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        pwEvent("folder_picker_cancelled")
    }
    private func folderNotice(_ controller: UIDocumentPickerViewController, title: String, message: String) {
        let presenter = folderPresenter
        controller.dismiss(animated: true) {
            guard let presenter = presenter, presenter.presentedViewController == nil else { return }
            let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            presenter.present(alert, animated: true)
        }
    }
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            guard url.isFileURL, try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
                throw pwError("Ouvre un dossier puis touche Ouvrir pour le sélectionner.")
            }
            // Probe only a new, uniquely named empty file in the user-selected folder.
            // This works for app-owned URLs as well as security-scoped File Providers.
            var coordinationError: NSError?, writeError: Error?
            NSFileCoordinator().coordinate(writingItemAt: url, options: .forMerging, error: &coordinationError) { directory in
                let probe = directory.appendingPathComponent(".pw-write-check-" + UUID().uuidString)
                do {
                    try Data().write(to: probe, options: .withoutOverwriting)
                    try FileManager.default.removeItem(at: probe)
                } catch { writeError = error }
            }
            if let error = writeError ?? coordinationError { throw error }
            let data = try url.bookmarkData(options: [.minimalBookmark], includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(data, forKey: pwFolderKey)
            UserDefaults.standard.set(url.lastPathComponent, forKey: "spotifyglass.download.folderName")
            PWDownloadStore.shared.importError = nil
            PWDownloadStore.shared.changed(); pwEvent("folder_selected")
            folderNotice(controller, title: "Dossier enregistré", message: "Les prochaines playlists seront enregistrées dans « \(url.lastPathComponent) ».")
        } catch {
            let message = "Dossier non enregistré : " + error.localizedDescription
            PWDownloadStore.shared.importError = message
            PWDownloadStore.shared.changed(); pwEvent("folder_selection_failed", (error as NSError).code, details: PWDownloadLog.error(error))
            folderNotice(controller, title: "Dossier inaccessible", message: message)
        }
    }
}

@MainActor
final class PWDownloadQueueController: UITableViewController {
    private let store = PWDownloadStore.shared
    private var observer: NSObjectProtocol?
    private var expandedError: String?
    private var errorIsExpanded: Bool { store.importError != nil && expandedError == store.importError }
    override func viewDidLoad() {
        super.viewDidLoad(); title = "Téléchargements"
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 90
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(close))
        refreshControls()
        observer = NotificationCenter.default.addObserver(forName: pwChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshControls(); self?.tableView.reloadData() }
        }
    }
    deinit { if let observer = observer { NotificationCenter.default.removeObserver(observer) } }
    @objc private func close() { dismiss(animated: true) }
    private func refreshControls() {
        let running = store.importing || store.jobs.contains { !$0.paused && $0.items.contains { $0.state == "pending" || $0.state == "working" } }
        navigationItem.leftBarButtonItems = [
            UIBarButtonItem(title: running ? "Pause" : "Reprendre", style: .plain, target: self, action: running ? #selector(pause) : #selector(resume)),
            UIBarButtonItem(title: "Vider", style: .plain, target: self, action: #selector(clearQueue))]
    }
    @objc private func pause() { store.pauseAll() }
    @objc private func resume() { store.resumeAll() }
    @objc private func clearQueue() {
        let alert = UIAlertController(title: "Vider la file ?", message: "Arrête les recherches et téléchargements, puis retire toutes les playlists de la liste. Les fichiers déjà enregistrés restent dans Fichiers.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Annuler", style: .cancel))
        alert.addAction(UIAlertAction(title: "Vider la file", style: .destructive) { [weak self] _ in self?.store.clearQueue() })
        present(alert, animated: true)
    }
    override func numberOfSections(in tableView: UITableView) -> Int { store.jobs.count + 1 }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? (1 + (store.consentSource == nil ? 0 : 1) + (store.availableImport == nil ? 0 : 1)) : store.jobs[section - 1].items.count + 1
    }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        section == 0 ? PWDownloadsBridge.summary : store.jobs[section - 1].title + (store.jobs[section - 1].paused ? " — en pause" : "")
    }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        if section == 0 { return "Fichiers audio disponibles dans Bibliothèque hors ligne. Ils sont distincts du cache Spotify. Garde l’app ouverte pendant la recherche ; iOS peut suspendre la file en arrière-plan. Touche un morceau enregistré pour le partager ou l’ouvrir dans une autre app." }
        let job = store.jobs[section - 1]
        return ["Source : \(pwSourceTitle(job.source)) · \(job.skipped) doublons, épisodes ou fichiers locaux ignorés.", job.notice].compactMap { $0 }.joined(separator: "\n")
    }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.textLabel?.numberOfLines = 0; cell.detailTextLabel?.numberOfLines = 0
        cell.textLabel?.lineBreakMode = .byWordWrapping
        cell.detailTextLabel?.lineBreakMode = .byWordWrapping
        cell.textLabel?.adjustsFontForContentSizeCategory = true
        cell.detailTextLabel?.adjustsFontForContentSizeCategory = true
        if indexPath.section == 0 {
            if indexPath.row > 0, let choice = store.availableImport,
               indexPath.row == (store.consentSource == nil ? 1 : 2) {
                cell.textLabel?.text = "Télécharger les \(Set(choice.native.tracks.map { $0.id }).count) morceaux disponibles"
                cell.detailTextLabel?.text = "\(choice.native.availableRows) éléments chargés sur \(choice.native.total) annoncés. Les éléments manquants ne seront pas ajoutés."
                cell.imageView?.image = UIImage(systemName: "arrow.down.circle")
                cell.accessoryType = .disclosureIndicator; return cell
            }
            if indexPath.row == 1 {
                cell.textLabel?.text = "Vérifier l’accès YouTube"
                cell.detailTextLabel?.text = "Choisis les cookies si Google le propose. Si YouTube s’affiche directement, touche Vérifier."
                cell.imageView?.image = UIImage(systemName: "globe")
                cell.accessoryType = .disclosureIndicator; return cell
            }
            if let error = store.importError {
                cell.textLabel?.text = "Téléchargement impossible"
                cell.detailTextLabel?.text = error
                cell.detailTextLabel?.numberOfLines = errorIsExpanded ? 0 : 3
                cell.accessoryView = UIImageView(image: UIImage(systemName: errorIsExpanded ? "chevron.up" : "chevron.down"))
                cell.accessibilityLabel = "Téléchargement impossible. " + error
                cell.accessibilityHint = errorIsExpanded ? "Toucher pour réduire. Appui long pour copier l’erreur." : "Toucher pour afficher l’erreur entière. Appui long pour la copier."
                cell.selectionStyle = .default
            } else {
                cell.textLabel?.text = store.importing ? "Chargement de tous les morceaux…" : "Dossier des prochaines playlists : " + PWDownloadsBridge.folderName
                cell.selectionStyle = .none
            }
            return cell
        }
        let job = store.jobs[indexPath.section - 1]
        if indexPath.row == 0 {
            cell.textLabel?.text = "Reprendre / réessayer les erreurs"
            cell.detailTextLabel?.text = job.lastError ?? (job.paused ? "En pause" : "Les morceaux déjà enregistrés sont conservés.")
            cell.imageView?.image = UIImage(systemName: "arrow.clockwise"); return cell
        }
        let item = job.items[indexPath.row - 1]
        cell.textLabel?.text = item.track.title + " — " + item.track.artist
        cell.detailTextLabel?.text = item.error ?? (item.state == "working" ? item.phase : nil) ?? (["pending": "En attente", "working": "Recherche et téléchargement…", "done": "Enregistré", "failed": "Échec"][item.state] ?? item.state)
        cell.imageView?.tintColor = item.state == "done" ? .systemGreen : .secondaryLabel
        cell.imageView?.image = UIImage(systemName: item.state == "done" ? "checkmark.circle.fill" : item.state == "failed" ? "exclamationmark.circle" : "arrow.down.circle")
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.section > 0 else {
            if indexPath.row > 0, store.availableImport != nil,
               indexPath.row == (store.consentSource == nil ? 1 : 2) {
                store.downloadAvailable(); return
            }
            if indexPath.row == 1, let request = store.consentRequest {
                let consent = PWYouTubeConsentController(request: request) { [weak self] in self?.store.consentCompleted() }
                let navigation = UINavigationController(rootViewController: consent)
                navigation.overrideUserInterfaceStyle = .dark
                present(navigation, animated: true); pwEvent("youtube_consent_opened", request.source)
                return
            }
            if let error = store.importError {
                expandedError = errorIsExpanded ? nil : error
                tableView.reloadRows(at: [indexPath], with: .automatic)
            }
            return
        }
        let job = store.jobs[indexPath.section - 1]
        if indexPath.row == 0 { store.resume(job.id); return }
        let item = job.items[indexPath.row - 1]
        guard item.state == "done", let entry = PWLocalLibrary.shared.available(item.track.id) else { return }
        PWLocalLibraryController.share(entry, from: self, anchor: tableView.cellForRow(at: indexPath))
    }
    override func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        let error: String?
        if indexPath.section == 0 { error = store.importError }
        else {
            let job = store.jobs[indexPath.section - 1]
            error = indexPath.row == 0 ? job.lastError : job.items[indexPath.row - 1].error
        }
        guard let message = error else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            UIMenu(children: [UIAction(title: "Copier l’erreur complète", image: UIImage(systemName: "doc.on.doc")) { _ in
                UIPasteboard.general.string = message
            }])
        }
    }
    override func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard indexPath.section > 0, indexPath.row == 0 else { return nil }
        let id = store.jobs[indexPath.section - 1].id
        let action = UIContextualAction(style: .destructive, title: "Retirer de la file") { [weak self] _, _, done in self?.store.remove(id); done(true) }
        return UISwipeActionsConfiguration(actions: [action])
    }
}
