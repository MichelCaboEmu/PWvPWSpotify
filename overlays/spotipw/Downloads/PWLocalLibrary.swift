import Foundation
import UIKit
import AVFoundation
import MediaPlayer
import Network

func pwSourceName(_ source: Int) -> String { source == 3 ? "audius" : source == 0 ? "youtube_music" : "youtube" }
func pwSourceTitle(_ source: Int) -> String { source == 3 ? "Audius — gratuit" : source == 0 ? "YouTube Music" : "YouTube" }

extension PWLocalEntry {
    func location() throws -> (root: URL, file: URL) {
        guard PWLibraryCatalog.safeComponent(directory), PWLibraryCatalog.safeComponent(filename) else { throw pwError("Chemin du fichier invalide.") }
        let job = PWDownloadJob(uri: "", title: "", source: 0, folder: folder, items: [], skipped: 0)
        let root = try PWDownloadFiles.root(for: job)
        return (root, root.appendingPathComponent(directory, isDirectory: true).appendingPathComponent(filename))
    }
    func exists() -> Bool {
        guard let location = try? location() else { return false }
        let scoped = location.root.startAccessingSecurityScopedResource()
        defer { if scoped { location.root.stopAccessingSecurityScopedResource() } }
        // An iCloud placeholder is not a file available offline.
        guard let values = try? location.file.resourceValues(forKeys: [.fileSizeKey, .ubiquitousItemDownloadingStatusKey]),
              (values.fileSize ?? 0) > 1024 else { return false }
        return values.ubiquitousItemDownloadingStatus == nil || values.ubiquitousItemDownloadingStatus == .current
    }
}

@MainActor
final class PWLocalLibrary {
    static let shared = PWLocalLibrary()
    private(set) var catalog = PWLibraryCatalog()
    private var availability: [String: (Date, Bool)] = [:]
    private var legacyExports: [PWLocalEntry] = []
    var metadataStatus = "Pochette, titre, artiste, album et année si disponibles"
    var metadataTask: Task<Void, Never>?
    var organizationTask: Task<Void, Never>?
    private var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PWDownloads/library.json")
    }
    private init() {
        if let bytes = try? Data(contentsOf: url), bytes.count < 48 * 1024 * 1024,
           let saved = try? JSONDecoder().decode(PWLibraryCatalog.self, from: bytes), saved.version == 1 { catalog = saved }
    }
    @discardableResult
    func persist() -> Bool {
        var saved = true
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(catalog).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch { saved = false; pwEvent("library_save_failed", details: PWDownloadLog.error(error)) }
        NotificationCenter.default.post(name: pwChanged, object: nil)
        return saved
    }
    func available(_ id: String, playlist: String? = nil) -> PWLocalEntry? {
        if let playlist = playlist {
            guard let entry = catalog.playlists[playlist]?.files?[id], entry.exists() else { return nil }
            return entry
        }
        if let entry = catalog.entries[id], entry.exists() { return entry }
        return catalog.playlists.values.compactMap { $0.files?[id] }.first { $0.exists() }
    }
    func rememberPlaylist(uri: String, title: String, tracks: [PWAudioTrack], complete: Bool) {
        catalog.remember(uri: uri, title: title, tracks: tracks, complete: complete)
        for track in tracks {
            if var entry = catalog.entries[track.id] {
                entry.track = entry.track.enriched(with: track); catalog.entries[track.id] = entry
            }
        }
        persist()
    }
    func record(track: PWAudioTrack, job: PWDownloadJob, stored: PWStoredFile, previous: PWLocalEntry? = nil) {
        var entry = previous ?? PWLocalEntry(track: track, folder: job.folder, directory: stored.directory, filename: stored.filename)
        entry.track = entry.track.enriched(with: track)
        entry.folder = job.folder; entry.directory = stored.directory; entry.filename = stored.filename; entry.playlistURI = job.uri
        replace(entry)
    }
    func replace(_ entry: PWLocalEntry) {
        if let uri = entry.playlistURI, catalog.playlists[uri] != nil {
            if catalog.playlists[uri]?.files == nil { catalog.playlists[uri]?.files = [:] }
            catalog.playlists[uri]?.files?[entry.track.id] = entry
        }
        catalog.entries[entry.track.id] = entry; persist()
    }
    var allFiles: [PWLocalEntry] {
        var result: [PWLocalEntry] = [], seen = Set<String>()
        for entry in Array(catalog.entries.values) + catalog.playlists.values.flatMap({ Array(($0.files ?? [:]).values) }) {
            let key = (entry.folder?.base64EncodedString() ?? "local") + "/" + entry.directory + "/" + entry.filename
            if seen.insert(key).inserted { result.append(entry) }
        }
        return result
    }
    func organizeLegacyFolders() async {
        // Copy first and persist every new path. Legacy files are deliberately
        // retained until the migration of every referenced playlist succeeds.
        let lists = Array(catalog.playlists.values)
        let old = allFiles.filter { $0.directory.hasPrefix("Playlist-") } + legacyExports
        legacyExports = []
        var failed = false
        for list in lists {
            for id in list.trackIDs {
                guard let entry = available(id, playlist: list.uri) ?? available(id), entry.directory.hasPrefix("Playlist-") || catalog.playlists[list.uri]?.files?[id] == nil else { continue }
                let job = PWDownloadJob(uri: list.uri, title: list.title, source: 0, folder: entry.folder, items: [], skipped: 0)
                do {
                    let file = try await PWDownloadFiles.shared.copyToPlaylist(entry, job: job)
                    record(track: entry.track, job: job, stored: file, previous: entry)
                } catch { failed = true; pwEvent("playlist_folder_migration_failed", details: PWDownloadLog.error(error)) }
            }
        }
        // Only remove catalog-owned old files after every replacement has been
        // persisted. Never remove another file in an exported directory.
        guard !failed, persist() else { return }
        let referenced = Set(allFiles.compactMap { try? $0.location().file.standardizedFileURL.path })
        var removed = 0, handled = Set<String>()
        for entry in old {
            guard let location = try? entry.location(), !referenced.contains(location.file.standardizedFileURL.path), handled.insert(location.file.standardizedFileURL.path).inserted else { continue }
            let scoped = location.root.startAccessingSecurityScopedResource()
            defer { if scoped { location.root.stopAccessingSecurityScopedResource() } }
            var error: NSError?
            NSFileCoordinator().coordinate(writingItemAt: location.file, options: .forDeleting, error: &error) { file in
                do {
                    try FileManager.default.removeItem(at: file); removed += 1
                    let directory = file.deletingLastPathComponent()
                    if (try? FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty) == true { try? FileManager.default.removeItem(at: directory) }
                } catch { pwEvent("legacy_file_cleanup_failed", details: PWDownloadLog.error(error)) }
            }
        }
        if !old.isEmpty { pwEvent("playlist_folders_organized", details: ["legacy_files_removed": removed]) }

    }
    func migrate(_ jobs: [PWDownloadJob]) {
        var imported = 0
        for job in jobs {
            // Never mark an old incomplete queue as a complete playlist.
            catalog.remember(uri: job.uri, title: job.title, tracks: job.items.map(\.track), complete: false)
            for item in job.items where item.state == "done" {
                guard let filename = item.file else { continue }
                let entry = PWLocalEntry(track: item.track, folder: job.folder, directory: "Playlist-" + job.id, filename: filename)
                if entry.exists() {
                    legacyExports.append(entry)
                    if catalog.entries[item.track.id] == nil { catalog.entries[item.track.id] = entry; imported += 1 }
                }
            }
        }
        if !jobs.isEmpty { persist() }
        if imported > 0 { pwEvent("library_migrated", imported) }
    }
    var playlists: [PWLocalPlaylist] {
        catalog.playlists.values.filter { playlist in playlist.trackIDs.contains { available($0) != nil } }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
}

@MainActor
final class PWOfflinePlayer: NSObject {
    static let shared = PWOfflinePlayer()
    private(set) var player: AVPlayer?
    private(set) var queue: [PWLocalEntry] = []
    private var orderedQueue: [PWLocalEntry] = []
    private(set) var repeatMode = 0
    private(set) var shuffled = false
    private(set) var artwork: UIImage?
    private var artworkTask: Task<Void, Never>?
    private(set) var index = 0
    var current: PWLocalEntry? { queue.indices.contains(index) ? queue[index] : nil }
    var elapsed: Double { let time = player?.currentTime().seconds ?? 0; return time.isFinite ? max(0, time) : 0 }
    var duration: Double { let time = player?.currentItem?.duration.seconds ?? 0; return time.isFinite && time > 0 ? time : current?.track.duration ?? 0 }
    private var access: URL?
    private var completion: NSObjectProtocol?
    private var failure: NSObjectProtocol?
    private var nowPlayingSession: MPNowPlayingSession?
    private var remoteTargets: [(MPRemoteCommand, Any)] = []
    var title: String { queue.indices.contains(index) ? queue[index].track.title : "Aucune lecture" }
    var playing: Bool { (player?.rate ?? 0) > 0 }
    func play(_ entries: [PWLocalEntry], at position: Int) throws {
        guard entries.indices.contains(position) else { return }
        stop()
        queue = entries; orderedQueue = entries; index = position
        try begin()
    }
    private func begin() throws {
        guard queue.indices.contains(index) else { stop(); return }
        releaseItem()
        let queued = queue[index]
        let entry = PWLocalLibrary.shared.available(queued.track.id, playlist: queued.playlistURI) ?? PWLocalLibrary.shared.available(queued.track.id) ?? queued
        queue[index] = entry
        let location = try entry.location()
        let scoped = location.root.startAccessingSecurityScopedResource()
        if scoped { access = location.root }
        guard entry.exists() else { releaseItem(); throw pwError("Ce fichier n’est plus disponible sur cet iPhone.") }
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try AVAudioSession.sharedInstance().setActive(true)
        // Existing shared player hook handles pause without guessing private selectors.
        NotificationCenter.default.post(name: Notification.Name("PWOfflinePlaybackStarting"), object: nil)
        let item = AVPlayerItem(url: location.file)
        player = AVPlayer(playerItem: item)
        completion = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.finished() }
        }
        failure = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] note in
            let message = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?.localizedDescription ?? "Lecture locale interrompue."
            Task { @MainActor in pwEvent("offline_playback_failed", details: ["message": message]); self?.stop() }
        }
        if let player = player {
            nowPlayingSession = MPNowPlayingSession(players: [player])
            installCommands()
            nowPlayingSession?.becomeActiveIfPossible { active in
                pwEvent("offline_session_active", active ? 1 : 0)
            }
        }
        artworkTask = Task { [weak self, weak item] in
            guard let item = item, let tags = try? await item.asset.load(.commonMetadata) else { return }
            var image: UIImage?
            for tag in tags where tag.commonKey == .commonKeyArtwork {
                if let bytes = try? await tag.load(.dataValue), let found = UIImage(data: bytes) { image = found; break }
            }
            guard !Task.isCancelled, self?.player?.currentItem === item else { return }
            self?.artwork = image; self?.nowPlaying(); NotificationCenter.default.post(name: pwChanged, object: nil)
        }
        player?.play(); nowPlaying(); NotificationCenter.default.post(name: pwChanged, object: nil)
    }
    private func installCommands() {
        guard let center = nowPlayingSession?.remoteCommandCenter else { return }
        for (command, action) in [(center.playCommand, 0), (center.pauseCommand, 1),
                                  (center.togglePlayPauseCommand, 2), (center.nextTrackCommand, 3), (center.previousTrackCommand, 4)] {
            let target = command.addTarget { [weak self] _ in
                Task { @MainActor in
                    guard let self = self else { return }
                    if action == 0 { self.player?.play(); self.nowPlaying() }
                    else if action == 1 { self.player?.pause(); self.nowPlaying() }
                    else if action == 2 { self.toggle() }
                    else if action == 3 { self.next() }
                    else { self.previous() }
                }
                return .success
            }
            remoteTargets.append((command, target))
        }
        let seek = center.changePlaybackPositionCommand
        let target = seek.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.seek(event.positionTime) }; return .success
        }
        remoteTargets.append((seek, target))
    }
    private func nowPlaying() {
        guard queue.indices.contains(index), let player = player else { return }
        let entry = queue[index]
        var info: [String: Any] = [MPMediaItemPropertyTitle: entry.track.title,
            MPMediaItemPropertyArtist: entry.track.artist, MPMediaItemPropertyAlbumTitle: entry.album ?? "",
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: max(0, player.currentTime().seconds.isFinite ? player.currentTime().seconds : 0),
            MPNowPlayingInfoPropertyPlaybackRate: player.rate]
        if let image = artwork { info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image } }
        nowPlayingSession?.nowPlayingInfoCenter.nowPlayingInfo = info
    }
    func toggle() { if playing { player?.pause() } else { player?.play() }; nowPlaying(); NotificationCenter.default.post(name: pwChanged, object: nil) }
    func seek(_ seconds: Double) {
        guard seconds.isFinite else { return }
        player?.seek(to: CMTime(seconds: min(duration, max(0, seconds)), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in Task { @MainActor in self?.nowPlaying() } }
    }
    func cycleRepeat() { repeatMode = (repeatMode + 1) % 3; NotificationCenter.default.post(name: pwChanged, object: nil) }
    func toggleShuffle() {
        guard let current = current else { return }
        shuffled.toggle()
        if shuffled { queue = [current] + queue.enumerated().filter { $0.offset != index }.map(\.element).shuffled(); index = 0 }
        else { queue = orderedQueue; index = queue.firstIndex { $0.track.id == current.track.id } ?? 0 }
        NotificationCenter.default.post(name: pwChanged, object: nil)
    }
    func jump(_ position: Int) {
        guard queue.indices.contains(position) else { return }
        index = position
        do { try begin() } catch { stop(); pwEvent("offline_playback_failed", details: PWDownloadLog.error(error)) }
    }
    private func finished() {
        if repeatMode == 2 { seek(0); player?.play(); nowPlaying() }
        else { next() }
    }
    func next() {
        if index + 1 < queue.count { jump(index + 1) }
        else if repeatMode > 0 { jump(0) }
        else { player?.pause(); nowPlaying(); NotificationCenter.default.post(name: pwChanged, object: nil) }
    }
    func previous() { if elapsed > 3 { seek(0) } else { jump(max(0, index - 1)) } }
    func remove(_ position: Int) {
        guard queue.indices.contains(position), position != index else { return }
        let removed = queue.remove(at: position)
        orderedQueue.removeAll { $0.track.id == removed.track.id }
        if position < index { index -= 1 }
        NotificationCenter.default.post(name: pwChanged, object: nil)
    }
    func move(_ source: Int, to destination: Int) {
        guard queue.indices.contains(source), queue.indices.contains(destination), let current = current else { return }
        let item = queue.remove(at: source); queue.insert(item, at: destination)
        index = queue.firstIndex { $0.track.id == current.track.id } ?? 0
        if !shuffled { orderedQueue = queue }
        NotificationCenter.default.post(name: pwChanged, object: nil)
    }
    private func releaseItem() {
        artworkTask?.cancel(); artworkTask = nil; artwork = nil
        player?.pause(); player = nil
        for (command, target) in remoteTargets { command.removeTarget(target) }; remoteTargets = []
        nowPlayingSession?.nowPlayingInfoCenter.nowPlayingInfo = nil; nowPlayingSession = nil
        for observer in [completion, failure].compactMap({ $0 }) { NotificationCenter.default.removeObserver(observer) }
        completion = nil; failure = nil
        if let access = access { access.stopAccessingSecurityScopedResource() }; access = nil
    }
    func stop() {
        releaseItem(); queue = []; orderedQueue = []; shuffled = false; repeatMode = 0
        NotificationCenter.default.post(name: pwChanged, object: nil)
    }
}

@MainActor
final class PWLocalLibraryController: UITableViewController {
    var playlist: PWLocalPlaylist?
    private var entries: [PWLocalEntry] = []
    private var lists: [PWLocalPlaylist] = []
    private var observer: NSObjectProtocol?
    override func viewDidLoad() {
        super.viewDidLoad(); overrideUserInterfaceStyle = .dark
        title = playlist?.title ?? "Bibliothèque hors ligne"
        tableView.rowHeight = UITableView.automaticDimension; tableView.estimatedRowHeight = 65
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(close))
        observer = NotificationCenter.default.addObserver(forName: pwChanged, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.reload() } }
        reload()
    }
    deinit { if let observer = observer { NotificationCenter.default.removeObserver(observer) } }
    private func reload() {
        lists = PWLocalLibrary.shared.playlists
        entries = playlist?.trackIDs.compactMap { PWLocalLibrary.shared.available($0, playlist: playlist?.uri) ?? PWLocalLibrary.shared.available($0) } ?? []
        let player = PWOfflinePlayer.shared
        navigationItem.prompt = player.player == nil ? nil : player.title
        toolbarItems = [UIBarButtonItem(title: player.title, style: .plain, target: self, action: #selector(openPlayer)),
            UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil),
            UIBarButtonItem(image: UIImage(systemName: player.playing ? "pause.fill" : "play.fill"), style: .plain, target: self, action: #selector(toggle))]
        navigationController?.setToolbarHidden(player.player == nil, animated: false)
        tableView.reloadData()
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if navigationController?.isBeingDismissed == true || isBeingDismissed { PWOfflinePlayer.shared.stop() }
    }
    @objc private func close() { PWOfflinePlayer.shared.stop(); dismiss(animated: true) }
    @objc private func openPlayer() { PWOfflinePlayerController.show(from: self) }
    @objc private func toggle() { PWOfflinePlayer.shared.toggle() }
    @objc private func nextTrack() { PWOfflinePlayer.shared.next() }
    @objc private func previous() { PWOfflinePlayer.shared.previous() }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { playlist == nil ? lists.count : entries.count }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        playlist == nil ? "Seules les playlists contenant des fichiers disponibles sur cet iPhone sont affichées. Touche une playlist pour écouter ses titres hors connexion." : "Appui long sur un titre pour partager le fichier."
    }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.textLabel?.numberOfLines = 0; cell.detailTextLabel?.numberOfLines = 0
        if playlist == nil {
            let list = lists[indexPath.row]
            cell.textLabel?.text = list.title
            cell.detailTextLabel?.text = "\(list.trackIDs.filter { PWLocalLibrary.shared.available($0) != nil }.count) / \(list.trackIDs.count) titres disponibles"
            cell.imageView?.image = UIImage(systemName: "music.note.list"); cell.accessoryType = .disclosureIndicator
        } else {
            let entry = entries[indexPath.row]
            cell.textLabel?.text = entry.track.title
            cell.detailTextLabel?.text = [entry.track.artist, entry.album, entry.year].compactMap { $0 }.joined(separator: " · ")
            cell.imageView?.image = UIImage(systemName: "checkmark.circle.fill"); cell.imageView?.tintColor = .systemGreen
        }
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if playlist == nil {
            let page = PWLocalLibraryController(style: .insetGrouped); page.playlist = lists[indexPath.row]
            navigationController?.pushViewController(page, animated: true)
        } else {
            do { try PWOfflinePlayer.shared.play(entries, at: indexPath.row); reload(); PWOfflinePlayerController.show(from: self) }
            catch { Self.notice(error.localizedDescription, from: self) }
        }
    }
    override func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        guard playlist != nil else { return nil }
        let entry = entries[indexPath.row]
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            UIMenu(children: [UIAction(title: "Partager le fichier", image: UIImage(systemName: "square.and.arrow.up")) { _ in
                guard let self = self else { return }; Self.share(entry, from: self, anchor: self.tableView)
            }])
        }
    }
    static func notice(_ message: String, from controller: UIViewController) {
        let alert = UIAlertController(title: "Téléchargements", message: message, preferredStyle: .alert)
        alert.overrideUserInterfaceStyle = .dark; alert.addAction(UIAlertAction(title: "OK", style: .default)); controller.present(alert, animated: true)
    }
    static func share(_ entry: PWLocalEntry, from controller: UIViewController, anchor: UIView?) {
        do {
            let location = try entry.location(), scoped = location.root.startAccessingSecurityScopedResource()
            guard FileManager.default.fileExists(atPath: location.file.path) else {
                if scoped { location.root.stopAccessingSecurityScopedResource() }; throw pwError("Fichier déplacé ou supprimé.")
            }
            let share = UIActivityViewController(activityItems: [location.file], applicationActivities: nil)
            share.popoverPresentationController?.sourceView = anchor ?? controller.view
            share.popoverPresentationController?.sourceRect = anchor?.bounds ?? controller.view.bounds
            share.completionWithItemsHandler = { _, _, _, _ in if scoped { location.root.stopAccessingSecurityScopedResource() } }
            controller.present(share, animated: true)
        } catch { notice(error.localizedDescription, from: controller) }
    }
}

@MainActor
final class PWOfflineStartup {
    static let shared = PWOfflineStartup()
    private let monitor = NWPathMonitor()
    private var handled = false
    private var offline = false
    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in self?.offline = path.status == .unsatisfied; self?.offer() }
        }
        monitor.start(queue: DispatchQueue(label: "PWOfflineNetwork"))
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.offer() }
        }
    }
    private func offer() {
        guard !handled, offline, UIApplication.shared.applicationState == .active,
              UserDefaults.standard.object(forKey: "spotifyglass.download.autoOffline") as? Bool ?? true else { return }
        _ = PWDownloadStore.shared // migrate the old queue before checking availability
        guard !PWLocalLibrary.shared.playlists.isEmpty else { return }
        // On launch Spotify can still be presenting its root; retry a bounded time.
        handled = true
        Task { @MainActor in
            for _ in 0..<10 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard offline else { return }
                if let controller = PWDownloadsBridge.topController(), controller.presentedViewController == nil,
                   controller.viewIfLoaded?.window != nil, !controller.isBeingPresented {
                    PWDownloadsBridge.library(from: controller); pwEvent("offline_library_opened"); return
                }
            }
            handled = false
        }
    }
}
