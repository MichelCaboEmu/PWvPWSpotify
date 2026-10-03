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
        entry.folder = job.folder; entry.directory = stored.directory; entry.filename = stored.filename; entry.playlistURI = job.storageURI
        replace(entry)
    }
    func replace(_ entry: PWLocalEntry) {
        if let uri = entry.playlistURI, catalog.playlists[uri] != nil {
            if catalog.playlists[uri]?.files == nil { catalog.playlists[uri]?.files = [:] }
            catalog.playlists[uri]?.files?[entry.track.id] = entry
        }
        catalog.entries[entry.track.id] = entry; persist()
        PWNativePlayback.importDownloaded(entry)
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
            catalog.remember(uri: job.storageURI, title: job.storageTitle, tracks: job.items.map(\.track), complete: false)
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
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "Fichiers locaux Spotify", style: .plain, target: self, action: #selector(openNativeFiles))
        observer = NotificationCenter.default.addObserver(forName: pwChanged, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.reload() } }
        reload()
    }
    deinit { if let observer = observer { NotificationCenter.default.removeObserver(observer) } }
    private func reload() {
        lists = PWLocalLibrary.shared.playlists
        entries = playlist?.trackIDs.compactMap { PWLocalLibrary.shared.available($0, playlist: playlist?.uri) ?? PWLocalLibrary.shared.available($0) } ?? []
        tableView.reloadData()
    }
    @objc private func close() { dismiss(animated: true) }
    @objc private func openNativeFiles() {
        dismiss(animated: true) { _ = PWNativePlayback.handler?(["operation":"open_files"]) }
    }
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
            PWNativePlayback.play(entries, at: indexPath.row, title: playlist?.title ?? "Titres téléchargés", from: self)
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
