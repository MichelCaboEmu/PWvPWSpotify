import Foundation
import UIKit
import UniformTypeIdentifiers
import AVFoundation

private let pwSourceKey = "spotifyglass.download.source"
private let pwFolderKey = "spotifyglass.download.folder"
private let pwChanged = Notification.Name("PWDownloadsChanged")
private func pwEvent(_ event: String, _ code: Int = 0) {
    NotificationCenter.default.post(name: Notification.Name("PWDownloadDiagnostic"), object: nil,
                                    userInfo: ["event": event, "code": code])
}
private struct PWDownloadError: LocalizedError {
    let message: String
    var pausesQueue = false
    var errorDescription: String? { message }
}
private func pwError(_ message: String) -> PWDownloadError { PWDownloadError(message: message) }

extension Bundle {
    static var pwYouTubeKit: Bundle {
        Bundle.main.url(forResource: "PWYouTubeKit", withExtension: "bundle").flatMap(Bundle.init(url:)) ?? .main
    }
}

// Separate sessions ensure the Spotify bearer never reaches the audio/search provider.
private final class PWDownloadHTTP: NSObject, URLSessionTaskDelegate {
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
        guard let url = request.url, url.scheme == "https", url.user == nil, url.password == nil else { completionHandler(nil); return }
        completionHandler((host != nil ? url.host == host : PWDownloadRules.mediaURL(url)) ? request : nil)
    }
    func data(_ request: URLRequest, stage: PWDownloadStage, maximum: Int = 12 * 1024 * 1024) async throws -> Data {
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { pwEvent(stage.rawValue + "_network", (error as NSError).code); throw error }
        guard let http = response as? HTTPURLResponse else { throw pwError("Réponse réseau invalide.") }
        guard http.statusCode == 200 else {
            pwEvent(stage.rawValue + "_http", http.statusCode)
            throw PWDownloadHTTPError(stage: stage, status: http.statusCode)
        }
        guard data.count < maximum else { throw pwError("La réponse du fournisseur est trop grande.") }
        return data
    }
    func json(_ request: URLRequest, stage: PWDownloadStage) async throws -> [String: Any] {
        let bytes = try await data(request, stage: stage)
        guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
            pwEvent(stage.rawValue + "_invalid_json")
            throw pwError("La réponse du fournisseur a changé de format.")
        }
        return object
    }

}

private struct PWDownloadItem: Codable {
    var track: PWAudioTrack
    var state = "pending"
    var file: String?
    var error: String?
}
private struct PWDownloadJob: Codable {
    var id = UUID().uuidString
    var uri: String
    var title: String
    var source: Int
    var folder: Data?
    var items: [PWDownloadItem]
    var skipped: Int
    var paused = false
    var lastError: String?
}

private actor PWDownloadFiles {
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
                    filename = UUID().uuidString + "-" + filename
                }
                let destination = granted.appendingPathComponent(filename)
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
private final class PWDownloadStore {
    static let shared = PWDownloadStore()
    var jobs: [PWDownloadJob] = []
    var importing = false
    var importError: String?
    private var worker: Task<Void, Never>?
    private var importer: Task<Void, Never>?
    private var activeID: String?
    private var background = UIBackgroundTaskIdentifier.invalid
    private let spotify = PWDownloadHTTP(host: "api.spotify.com")
    private let music = PWDownloadHTTP(host: "music.youtube.com")
    private let youtube = PWDownloadHTTP(host: "www.youtube.com")
    private let media = PWDownloadHTTP(host: nil)
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
    }
    func changed() {
        do {
            try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(jobs).write(to: stateURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch { pwEvent("queue_save_failed", (error as NSError).code) }
        NotificationCenter.default.post(name: pwChanged, object: nil)
    }
    func importPlaylist(uri: String, title: String, authorization: String, native: PWNativePlaylist? = nil) {
        if jobs.contains(where: { $0.uri == uri }) { return }
        guard !importing else { importError = "Une autre playlist est déjà en cours de chargement."; changed(); return }
        guard jobs.count < 50 else { importError = "La file contient 50 playlists. Retire une ancienne playlist de la liste."; changed(); return }
        guard let path = PWDownloadRules.playlistPath(uri) else { importError = "Cette page n’est pas une playlist compatible."; changed(); return }
        if let native = native, native.complete {
            var seen = Set<String>()
            let unique = native.tracks.filter { seen.insert($0.id).inserted }
            guard !unique.isEmpty else { importError = "Aucun morceau audio pris en charge dans cette playlist."; changed(); return }
            jobs.append(PWDownloadJob(uri: uri, title: title, source: min(UserDefaults.standard.integer(forKey: pwSourceKey), 1),
                                      folder: UserDefaults.standard.data(forKey: pwFolderKey),
                                      items: unique.map { PWDownloadItem(track: $0) }, skipped: native.total - unique.count))
            importError = nil; pwEvent("playlist_native_loaded", native.total)
            pwEvent("playlist_queued", unique.count); changed(); start(); return
        }
        pwEvent(native == nil ? "playlist_native_unavailable" : "playlist_native_incomplete", native?.total ?? 0)
        guard authorization.hasPrefix("Bearer ") else { importError = "Lance une chanson pour initialiser la session Spotify, puis réessaie la flèche."; changed(); return }
        importing = true; importError = nil; changed()
        let source = UserDefaults.standard.integer(forKey: pwSourceKey)
        let folder = UserDefaults.standard.data(forKey: pwFolderKey)
        importer = Task {
            defer { importing = false; importer = nil; changed() }
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
                jobs.append(PWDownloadJob(uri: uri, title: title, source: min(source, 1), folder: folder,
                                          items: unique.map { PWDownloadItem(track: $0) }, skipped: read - unique.count))
                pwEvent("playlist_queued", unique.count); changed(); start()
            } catch is CancellationError { importError = "Chargement annulé." }
            catch {
                if let http = error as? PWDownloadHTTPError, http.status == 404, let problem = native?.problem {
                    importError = problem + " L’API Spotify renvoie aussi HTTP 404."
                } else { importError = error.localizedDescription }
                pwEvent("playlist_failed", (error as NSError).code)
            }
        }
    }
    func pauseAll() {
        importer?.cancel()
        for j in jobs.indices { jobs[j].paused = true }
        worker?.cancel(); changed()
    }
    func resume(_ id: String) {
        guard let j = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[j].paused = false; jobs[j].lastError = nil
        for i in jobs[j].items.indices where jobs[j].items[i].state == "failed" { jobs[j].items[i].state = "pending"; jobs[j].items[i].error = nil }
        changed(); start()
    }
    func remove(_ id: String) {
        if activeID == id { worker?.cancel() }
        jobs.removeAll { $0.id == id }; changed()
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
                activeID = job.id; jobs[j].items[i].state = "working"; changed()
                do {
                    let temporary = try await fetchAudio(track, source: job.source)
                    defer { try? FileManager.default.removeItem(at: temporary) }
                    try Task.checkCancellation()
                    let file = try await PWDownloadFiles.shared.save(temporary, track: track, job: job)
                    update(job.id, track.id, state: "done", file: file)
                    pwEvent("audio_saved")
                } catch {
                    let cancelled = Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled
                    update(job.id, track.id, state: cancelled ? "pending" : "failed", error: cancelled ? nil : error.localizedDescription)
                    pwEvent(cancelled ? "audio_paused" : "audio_failed", (error as NSError).code)
                    if cancelled { break }
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
    private func fetchAudio(_ track: PWAudioTrack, source: Int) async throws -> URL {
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
        var body: [String: Any] = ["query": track.title + " " + track.artist, "context": configuration.context]
        if isMusic { body["params"] = "EgWKAQIIAWoKEAkQBRAKEAMQBA==" }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let json: [String: Any]
        do { json = try await client.json(request, stage: isMusic ? .youtubeMusicSearch : .youtubeSearch) }
        catch { searchConfigs.removeValue(forKey: source); throw error }
        let candidates = PWDownloadRules.candidates(json, music: isMusic).compactMap { candidate -> (PWAudioCandidate, Int)? in
            PWDownloadRules.score(candidate, for: track).map { (candidate, $0) }
        }.sorted { $0.1 > $1.1 }
        guard let candidate = candidates.first?.0 else { throw pwError("Aucune correspondance sûre pour le titre, l’artiste et la durée. Essaie l’autre source.") }
        try Task.checkCancellation()
        // Explicitly local: YouTubeKit's optional remote service is never enabled.
        let video = YouTube(videoID: candidate.id, methods: [.local])
        let streams: [Stream]
        do { streams = try await video.streams }
        catch {
            try Task.checkCancellation()
            if (error as? URLError)?.code == .cancelled { throw error }
            pwEvent("local_extraction_failed", (error as NSError).code)
            throw PWDownloadError(message: "Extraction YouTube indisponible. Le fournisseur peut refuser l’accès ou avoir changé son format. La file est en pause ; exporte les logs depuis les paramètres pour le diagnostic.", pausesQueue: true)
        }
        guard let stream = streams.filterAudioOnly().filter({ $0.fileExtension == .m4a }).highestAudioBitrateStream(),
              PWDownloadRules.mediaURL(stream.url) else { throw pwError("Aucun flux M4A compatible accessible sur cet iPhone.") }
        // YouTube can require a short interval before allowing the resolved stream.
        var temporary: URL?
        for attempt in 0..<2 {
            try Task.checkCancellation()
            let (file, response) = try await media.session.download(from: stream.url)
            guard let http = response as? HTTPURLResponse else { try? FileManager.default.removeItem(at: file); throw pwError("Réponse audio invalide.") }
            if http.statusCode == 403 && attempt == 0 {
                try? FileManager.default.removeItem(at: file)
                try await Task.sleep(nanoseconds: 6_000_000_000)
                continue
            }
            guard http.statusCode == 200, let finalURL = http.url, PWDownloadRules.mediaURL(finalURL) else {
                try? FileManager.default.removeItem(at: file); throw pwError("Flux audio refusé (HTTP \(http.statusCode)). Réessaie plus tard.")
            }
            temporary = file; break
        }
        guard let file = temporary else { throw pwError("Le fournisseur ne permet pas de télécharger ce morceau pour le moment.") }
        do {
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 1024, size <= 128 * 1024 * 1024 else { throw pwError("Fichier audio vide ou trop volumineux (limite 128 Mo).") }
            let asset = AVURLAsset(url: file)
            let duration = try await asset.load(.duration).seconds
            let audio = try await asset.loadTracks(withMediaType: .audio)
            guard !audio.isEmpty, duration.isFinite, abs(duration - track.duration) <= max(8, track.duration * 0.05) else {
                throw pwError("Le fichier reçu est incomplet ou sa durée ne correspond pas au morceau.")
            }
            return file
        } catch { try? FileManager.default.removeItem(at: file); throw error }
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
    @objc(presentFrom:playlistURI:title:authorization:)
    static func present(from controller: UIViewController, playlistURI: String?, title: String?, authorization: String?) {
        present(from: controller, playlistURI: playlistURI, title: title, authorization: authorization, nativeModel: nil)
    }
    @objc(presentFrom:playlistURI:title:authorization:nativeModel:)
    static func present(from controller: UIViewController, playlistURI: String?, title: String?, authorization: String?, nativeModel: AnyObject?) {
        let vc = PWDownloadQueueController(style: .insetGrouped)
        if let uri = playlistURI {
            let native = nativeModel.flatMap { PWNativePlaylist.read(header: $0, requestedURI: uri) }
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
            PWDownloadStore.shared.changed(); pwEvent("folder_selection_failed", (error as NSError).code)
            folderNotice(controller, title: "Dossier inaccessible", message: message)
        }
    }
}

@MainActor
private final class PWDownloadQueueController: UITableViewController {
    private let store = PWDownloadStore.shared
    private var observer: NSObjectProtocol?
    private var sharingRoot: URL?
    override func viewDidLoad() {
        super.viewDidLoad(); title = "Téléchargements"
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(close))
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "Pause", style: .plain, target: self, action: #selector(pause))
        observer = NotificationCenter.default.addObserver(forName: pwChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.tableView.reloadData() }
        }
    }
    deinit { if let observer = observer { NotificationCenter.default.removeObserver(observer) } }
    @objc private func close() { dismiss(animated: true) }
    @objc private func pause() { store.pauseAll() }
    override func numberOfSections(in tableView: UITableView) -> Int { store.jobs.count + 1 }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? 1 : store.jobs[section - 1].items.count + 1
    }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        section == 0 ? PWDownloadsBridge.summary : store.jobs[section - 1].title
    }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        if section == 0 { return "Fichiers M4A provenant de YouTube. Ils sont distincts du cache hors ligne Spotify. Garde l’app ouverte pendant la recherche ; iOS peut suspendre la file en arrière-plan. Touche un morceau enregistré pour le partager ou l’ouvrir dans une autre app." }
        let job = store.jobs[section - 1]
        return "Source : \(job.source == 0 ? "YouTube Music" : "YouTube") · \(job.skipped) doublons, épisodes ou fichiers locaux ignorés."
    }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.textLabel?.numberOfLines = 2; cell.detailTextLabel?.numberOfLines = 0
        if indexPath.section == 0 {
            cell.textLabel?.text = store.importError ?? (store.importing ? "Chargement de tous les morceaux…" : "Dossier des prochaines playlists : " + PWDownloadsBridge.folderName)
            cell.selectionStyle = .none; return cell
        }
        let job = store.jobs[indexPath.section - 1]
        if indexPath.row == 0 {
            cell.textLabel?.text = "Reprendre / réessayer les erreurs"
            cell.detailTextLabel?.text = job.lastError ?? (job.paused ? "En pause" : "Les morceaux déjà enregistrés sont conservés.")
            cell.imageView?.image = UIImage(systemName: "arrow.clockwise"); return cell
        }
        let item = job.items[indexPath.row - 1]
        cell.textLabel?.text = item.track.title + " — " + item.track.artist
        cell.detailTextLabel?.text = item.error ?? (["pending": "En attente", "working": "Recherche et téléchargement…", "done": "Enregistré", "failed": "Échec"][item.state] ?? item.state)
        cell.imageView?.image = UIImage(systemName: item.state == "done" ? "checkmark.circle.fill" : item.state == "failed" ? "exclamationmark.circle" : "arrow.down.circle")
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.section > 0 else { return }
        let job = store.jobs[indexPath.section - 1]
        if indexPath.row == 0 { store.resume(job.id); return }
        let item = job.items[indexPath.row - 1]
        guard item.state == "done", let name = item.file else { return }
        do {
            let root = try PWDownloadFiles.root(for: job)
            let scoped = root.startAccessingSecurityScopedResource()
            let file = root.appendingPathComponent("Playlist-" + job.id).appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: file.path) else {
                if scoped { root.stopAccessingSecurityScopedResource() }
                throw pwError("Le fichier a été déplacé ou supprimé dans Fichiers.")
            }
            let share = UIActivityViewController(activityItems: [file], applicationActivities: nil)
            share.popoverPresentationController?.sourceView = tableView.cellForRow(at: indexPath)
            share.completionWithItemsHandler = { _, _, _, _ in if scoped { root.stopAccessingSecurityScopedResource() } }
            present(share, animated: true)
        } catch {
            let alert = UIAlertController(title: "Fichier indisponible", message: error.localizedDescription, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default)); present(alert, animated: true)
        }
    }
    override func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard indexPath.section > 0, indexPath.row == 0 else { return nil }
        let id = store.jobs[indexPath.section - 1].id
        let action = UIContextualAction(style: .destructive, title: "Retirer de la file") { [weak self] _, _, done in self?.store.remove(id); done(true) }
        return UISwipeActionsConfiguration(actions: [action])
    }
}
