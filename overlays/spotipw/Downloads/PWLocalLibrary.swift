import Foundation
import UIKit
import AVFoundation
import MediaPlayer
import Network

func pwSourceName(_ source: Int) -> String { source == 3 ? "soundcloud" : source == 0 ? "youtube_music" : "youtube" }
func pwSourceTitle(_ source: Int) -> String { source == 3 ? "SoundCloud" : source == 0 ? "YouTube Music" : "YouTube" }

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
    var metadataStatus = "Pochette, titre, artiste, album et année si disponibles"
    var metadataTask: Task<Void, Never>?
    private var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PWDownloads/library.json")
    }
    private init() {
        if let bytes = try? Data(contentsOf: url), bytes.count < 48 * 1024 * 1024,
           let saved = try? JSONDecoder().decode(PWLibraryCatalog.self, from: bytes), saved.version == 1 { catalog = saved }
    }
    func persist() {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(catalog).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch { pwEvent("library_save_failed", details: PWDownloadLog.error(error)) }
        NotificationCenter.default.post(name: pwChanged, object: nil)
    }
    func available(_ id: String) -> PWLocalEntry? {
        guard let entry = catalog.entries[id] else { return nil }
        if let cached = availability[id], Date().timeIntervalSince(cached.0) < 1 { return cached.1 ? entry : nil }
        let present = entry.exists(); availability[id] = (Date(), present)
        return present ? entry : nil
    }
    func rememberPlaylist(uri: String, title: String, tracks: [PWAudioTrack], complete: Bool) {
        catalog.remember(uri: uri, title: title, tracks: tracks, complete: complete); persist()
    }
    func record(track: PWAudioTrack, job: PWDownloadJob, filename: String) {
        availability.removeValue(forKey: track.id)
        catalog.entries[track.id] = PWLocalEntry(track: track, folder: job.folder, directory: "Playlist-" + job.id, filename: filename)
        persist()
    }
    func replace(_ entry: PWLocalEntry) { availability.removeValue(forKey: entry.track.id); catalog.entries[entry.track.id] = entry; persist() }
    func migrate(_ jobs: [PWDownloadJob]) {
        var imported = 0
        for job in jobs {
            // Never mark an old incomplete queue as a complete playlist.
            catalog.remember(uri: job.uri, title: job.title, tracks: job.items.map(\.track), complete: false)
            for item in job.items where item.state == "done" {
                guard catalog.entries[item.track.id] == nil, let filename = item.file else { continue }
                let entry = PWLocalEntry(track: item.track, folder: job.folder, directory: "Playlist-" + job.id, filename: filename)
                if entry.exists() { catalog.entries[item.track.id] = entry; imported += 1 }
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
    private var queue: [PWLocalEntry] = []
    private var index = 0
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
        queue = entries; index = position
        try begin()
    }
    private func begin() throws {
        guard queue.indices.contains(index) else { stop(); return }
        releaseItem()
        let entry = queue[index], location = try entry.location()
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
            Task { @MainActor in self?.next() }
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
    }
    private func nowPlaying() {
        guard queue.indices.contains(index), let player = player else { return }
        let entry = queue[index]
        nowPlayingSession?.nowPlayingInfoCenter.nowPlayingInfo = [MPMediaItemPropertyTitle: entry.track.title,
            MPMediaItemPropertyArtist: entry.track.artist, MPMediaItemPropertyAlbumTitle: entry.album ?? "",
            MPMediaItemPropertyPlaybackDuration: entry.track.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: max(0, player.currentTime().seconds.isFinite ? player.currentTime().seconds : 0),
            MPNowPlayingInfoPropertyPlaybackRate: player.rate]
    }
    func toggle() { if playing { player?.pause() } else { player?.play() }; nowPlaying(); NotificationCenter.default.post(name: pwChanged, object: nil) }
    func next() { index += 1; do { try begin() } catch { stop(); pwEvent("offline_playback_failed", details: PWDownloadLog.error(error)) } }
    func previous() { index = max(0, index - 1); do { try begin() } catch { stop() } }
    private func releaseItem() {
        player?.pause(); player = nil
        for (command, target) in remoteTargets { command.removeTarget(target) }; remoteTargets = []
        nowPlayingSession?.nowPlayingInfoCenter.nowPlayingInfo = nil; nowPlayingSession = nil
        for observer in [completion, failure].compactMap({ $0 }) { NotificationCenter.default.removeObserver(observer) }
        completion = nil; failure = nil
        if let access = access { access.stopAccessingSecurityScopedResource() }; access = nil
    }
    func stop() {
        releaseItem(); queue = []
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
        entries = playlist?.trackIDs.compactMap { PWLocalLibrary.shared.available($0) } ?? []
        let player = PWOfflinePlayer.shared
        navigationItem.prompt = player.player == nil ? nil : player.title
        toolbarItems = [UIBarButtonItem(image: UIImage(systemName: "backward.end.fill"), style: .plain, target: self, action: #selector(previous)),
            UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil),
            UIBarButtonItem(image: UIImage(systemName: player.playing ? "pause.fill" : "play.fill"), style: .plain, target: self, action: #selector(toggle)),
            UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil),
            UIBarButtonItem(image: UIImage(systemName: "forward.end.fill"), style: .plain, target: self, action: #selector(nextTrack))]
        navigationController?.setToolbarHidden(player.player == nil, animated: false)
        tableView.reloadData()
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if navigationController?.isBeingDismissed == true || isBeingDismissed { PWOfflinePlayer.shared.stop() }
    }
    @objc private func close() { PWOfflinePlayer.shared.stop(); dismiss(animated: true) }
    @objc private func toggle() { PWOfflinePlayer.shared.toggle() }
    @objc private func nextTrack() { PWOfflinePlayer.shared.next() }
    @objc private func previous() { PWOfflinePlayer.shared.previous() }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { playlist == nil ? lists.count : entries.count }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        playlist == nil ? "Seules les playlists contenant des fichiers disponibles sur cet iPhone sont affichées. Ce lecteur utilise tes fichiers téléchargés ; le cache Spotify reste séparé." : "Appui long sur un titre pour partager le fichier."
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
            do { try PWOfflinePlayer.shared.play(entries, at: indexPath.row); reload() }
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
