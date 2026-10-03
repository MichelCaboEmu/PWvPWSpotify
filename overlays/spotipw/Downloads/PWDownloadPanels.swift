import Foundation
import UIKit
import ObjectiveC

extension PWDownloadsBridge {
    static func topController() -> UIViewController? {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }.flatMap(\.windows)
        var result = windows.first(where: \.isKeyWindow)?.rootViewController
        while let presented = result?.presentedViewController { result = presented }
        return result
    }
    static func panel(_ controller: UIViewController, from presenter: UIViewController) {
        let nav = UINavigationController(rootViewController: controller); nav.overrideUserInterfaceStyle = .dark
        nav.view.tintColor = UIColor(red: 0.12, green: 0.84, blue: 0.38, alpha: 1)
        presenter.present(nav, animated: true)
    }
    @objc(libraryFrom:)
    static func library(from presenter: UIViewController) {
        _ = PWDownloadStore.shared
        panel(PWLocalLibraryController(style: .insetGrouped), from: presenter)
    }
    @objc(errorsFrom:)
    static func errors(from presenter: UIViewController) { panel(PWDownloadErrorsController(style: .insetGrouped), from: presenter) }
    @objc static var errorSummary: String {
        let count = PWDownloadStore.shared.jobs.flatMap(\.items).filter { $0.state == "failed" }.count
        let metadata = PWLocalLibrary.shared.catalog.entries.values.filter { $0.metadataError != nil }.count
        return "\(count) titres · \(metadata) erreurs de métadonnées"
    }
    @objc static var metadataSummary: String { PWLocalLibrary.shared.metadataStatus }
    @objc(metadataFrom:)
    static func metadata(from presenter: UIViewController) {
        _ = PWDownloadStore.shared
        panel(PWMetadataController(style: .insetGrouped), from: presenter)
    }
    @objc static func startOfflineMonitor() { PWOfflineStartup.shared.start() }
    // FTPViewController owns playlistViewModel; the header controller is a sibling,
    // not an ancestor of a track cell. Field verified in 9.1.78 Swift metadata.
    @objc(playlistModelFromController:)
    static func playlistModel(from controller: UIViewController) -> AnyObject? {
        guard String(reflecting: type(of: controller)).contains("FTPViewController"),
              let model = PWNativePlaylist.field(controller, "playlistViewModel") else { return nil }
        return model as AnyObject
    }
    private static var nativeCache: (key: ObjectIdentifier, uri: String, time: Date, tracks: [PWAudioTrack])?
    @objc(trackInfoFromModel:uri:title:subtitle:)
    static func trackInfo(model: AnyObject, uri: String, title: String, subtitle: String) -> NSDictionary? {
        _ = PWDownloadStore.shared
        let key = ObjectIdentifier(model)
        let tracks: [PWAudioTrack]
        if let cached = nativeCache, cached.key == key, cached.uri == uri, Date().timeIntervalSince(cached.time) < 1 {
            tracks = cached.tracks
        } else {
            tracks = PWNativePlaylist.menuTracks(header: model, requestedURI: uri)
            nativeCache = (key, uri, Date(), tracks)
        }
        // Resolve only exact, unambiguous displayed titles in THIS playlist.
        // Do not infer a Spotify ID from a row number or from the playing song.
        let names = PWDownloadRules.words(title), detail = PWDownloadRules.words(subtitle)
        let matching = tracks.filter { PWDownloadRules.words($0.title) == names && PWDownloadRules.phrase(PWDownloadRules.words($0.artist), in: detail) }
        let ids = Set(matching.map(\.id))
        guard ids.count == 1, let track = matching.first else { return nil }
        var info: [String: Any] = ["id": track.id, "title": track.title, "artist": track.artist, "duration": track.duration,
                "saved": PWLocalLibrary.shared.available(track.id) != nil]
        info["album"] = track.album; info["artwork"] = track.artworkURL
        return info as NSDictionary
    }
    private static var menuTrack: (selection: PWTrackMenuSelection, time: Date)?
    @objc(selectMenuTrack:)
    static func selectMenuTrack(_ info: NSDictionary?) {
        menuTrack = nil
        guard let id = info?["id"] as? String, let title = info?["title"] as? String,
              let artist = info?["artist"] as? String, let duration = info?["duration"] as? Double else { return }
        let track = PWAudioTrack(id: id, title: title, artist: artist, duration: duration, album: info?["album"] as? String, artworkURL: (info?["artwork"] as? String).flatMap(PWMetadataRules.artworkURL))
        let destination = PWDownloadDestination(uri: info?["playlistURI"] as? String, title: info?["playlistTitle"] as? String)
        menuTrack = (PWTrackMenuSelection(track, destination: destination), Date())
    }
    @objc(setSpotifyAuthorization:)
    static func setSpotifyAuthorization(_ authorization: String?) {
        if let authorization = authorization, authorization.hasPrefix("Bearer ") { PWMetadata.spotifyAuthorization = authorization }
    }
    private static var menuSelectionKey: UInt8 = 0
    private static var menuButtonKey: UInt8 = 0
    private static var menuLayoutLoggedKey: UInt8 = 0
    @objc(decorateDownloadSubtitle:downloaded:)
    static func decorateDownloadSubtitle(_ root: UIView?, downloaded: Bool) {
        guard let root = root else { return }
        func labels(_ view: UIView) -> [UILabel] {
            if let label = view as? UILabel { return [label] }
            return view.subviews.flatMap { labels($0) }
        }
        let all = labels(root)
        let artist = all.max { ($0.text?.count ?? 0) < ($1.text?.count ?? 0) }
        for label in all { PWDownloadedIndicator.apply(to: label, downloaded: downloaded && label === artist) }
    }
    @objc(installTrackMenu:)
    static func installTrackMenu(_ menu: UIViewController) {
        let selection: PWTrackMenuSelection
        if let box = objc_getAssociatedObject(menu, &menuSelectionKey) as? PWTrackMenuSelection { selection = box }
        else {
            guard let pending = menuTrack, Date().timeIntervalSince(pending.time) < 4 else { return }
            selection = pending.selection
            objc_setAssociatedObject(menu, &menuSelectionKey, selection, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            menuTrack = nil
        }
        func table(_ view: UIView, _ depth: Int = 0) -> UITableView? {
            if let view = view as? UITableView { return view }
            guard depth < 7 else { return nil }
            return view.subviews.compactMap { table($0, depth + 1) }.first
        }
        guard let rows = table(menu.view), rows.bounds.width > 0 else { return }
        if let button = objc_getAssociatedObject(menu, &menuButtonKey) as? UIButton, button.isDescendant(of: rows) {
            refreshTrackMenuHeader(rows); _ = PWTrackMenuLayout.compact(table: rows, in: menu.view); return
        }
        let button = UIButton(type: .system)
        button.frame = CGRect(x: 0, y: 0, width: rows.bounds.width, height: 58)
        button.overrideUserInterfaceStyle = .dark
        let saved = PWLocalLibrary.shared.available(selection.track.id) != nil
        var config = UIButton.Configuration.plain()
        config.title = saved ? "Téléchargé sur cet iPhone" : "Télécharger ce titre"
        config.image = PWSpotifyVisuals.icon(saved ? "downloaded" : "download", size: 24, color: saved ? .systemGreen : .white) ?? UIImage(systemName: "arrow.down.circle")
        config.imagePadding = 14; config.baseForegroundColor = saved ? .systemGreen : .label
        config.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16)
        button.configuration = config; button.contentHorizontalAlignment = .leading
        button.addAction(UIAction { [weak menu] _ in
            guard let menu = menu else { return }
            chooseSource(selection.track, from: menu, destination: selection.destination)
        }, for: .touchUpInside)
        // Header is adjacent to the first action. Never append after Spotify's
        // footer: it may be a screen-height spacer. Keep native header content.
        let wrapper = PWTrackMenuHeader(prior: rows.tableHeaderView, button: button, width: rows.bounds.width)
        rows.tableHeaderView = wrapper
        objc_setAssociatedObject(menu, &menuButtonKey, button, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        _ = PWTrackMenuLayout.compact(table: rows, in: menu.view)
        rows.invalidateIntrinsicContentSize()
        if objc_getAssociatedObject(menu, &menuLayoutLoggedKey) == nil {
            objc_setAssociatedObject(menu, &menuLayoutLoggedKey, true, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            DispatchQueue.main.async { [weak menu, weak rows] in
                guard let menu = menu, let rows = rows else { return }
                let rect = menu.view.convert(rows.bounds, from: rows)
                pwEvent("track_menu_geometry", details: ["table_y":rect.minY, "table_height":rect.height,
                    "header_height":rows.tableHeaderView?.bounds.height ?? 0, "inset_top":rows.adjustedContentInset.top,
                    "offset_y":rows.contentOffset.y, "root_height":menu.view.bounds.height])
            }
        }
    }
    @objc(refreshTrackMenuHeader:)
    static func refreshTrackMenuHeader(_ table: UITableView) {
        guard let header = table.tableHeaderView as? PWTrackMenuHeader else { return }
        if header.resize(width: table.bounds.width, table: table) { table.tableHeaderView = header }
    }
    static func chooseSource(_ track: PWAudioTrack, from presenter: UIViewController, destination: PWDownloadDestination? = nil) {
        let alert = UIAlertController(title: track.title, message: track.artist + (destination.map { "\nDossier : " + $0.title } ?? ""), preferredStyle: .actionSheet)
        alert.overrideUserInterfaceStyle = .dark
        if let entry = PWLocalLibrary.shared.available(track.id) {
            alert.addAction(UIAlertAction(title: "Écouter le fichier téléchargé", style: .default) { _ in
                PWNativePlayback.play([entry], at: 0, title: destination?.title ?? "Titre téléchargé", from: presenter)
            })
            alert.addAction(UIAlertAction(title: "Partager le fichier", style: .default) { _ in PWLocalLibraryController.share(entry, from: presenter, anchor: presenter.view) })
        }
        if let destination = destination, PWLocalLibrary.shared.available(track.id) != nil,
           PWLocalLibrary.shared.available(track.id, playlist: destination.uri) == nil {
            alert.addAction(UIAlertAction(title: "Ajouter au dossier « \(destination.title) »", style: .default) { _ in
                PWDownloadStore.shared.downloadTrack(track, source: PWDownloadStore.selectedSource, destination: destination)
                panel(PWDownloadQueueController(style: .insetGrouped), from: presenter)
            })
        }
        if PWLocalLibrary.shared.available(track.id) == nil {
            for source in [0, 1, 3] {
                alert.addAction(UIAlertAction(title: pwSourceTitle(source), style: .default) { _ in
                    PWDownloadStore.shared.downloadTrack(track, source: source, destination: destination)
                    panel(PWDownloadQueueController(style: .insetGrouped), from: presenter)
                })
            }
        }
        alert.addAction(UIAlertAction(title: "Annuler", style: .cancel))
        alert.popoverPresentationController?.sourceView = presenter.view
        alert.popoverPresentationController?.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 1, height: 1)
        presenter.present(alert, animated: true)
    }
}

@MainActor
final class PWDownloadErrorsController: UITableViewController {
    private var rows: [(String, String)] = []
    private var observer: NSObjectProtocol?
    override func viewDidLoad() {
        super.viewDidLoad(); title = "Titres en erreur"; overrideUserInterfaceStyle = .dark
        tableView.rowHeight = UITableView.automaticDimension; tableView.estimatedRowHeight = 120
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(close))
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "Réessayer", style: .plain, target: self, action: #selector(retry))
        observer = NotificationCenter.default.addObserver(forName: pwChanged, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.reload() } }
        reload()
    }
    deinit { if let observer = observer { NotificationCenter.default.removeObserver(observer) } }
    func reload() {
        rows = PWDownloadStore.shared.jobs.flatMap { job in job.items.filter { $0.state == "failed" }.map {
            ($0.track.title + " — " + $0.track.artist + "\n" + job.title, $0.error ?? "Échec sans détail")
        } }
        rows += PWLocalLibrary.shared.catalog.entries.values.compactMap { entry in entry.metadataError.map { (entry.track.title + " — métadonnées", $0) } }
        tableView.reloadData()
    }
    @objc func retry() {
        // Retry only failed audio items; do not start unrelated pending playlists.
        let store = PWDownloadStore.shared
        for job in store.jobs where job.items.contains(where: { $0.state == "failed" }) { store.resume(job.id) }
    }
    @objc func close() { dismiss(animated: true) }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { rows.count }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? { rows.isEmpty ? "Aucune erreur enregistrée." : "Les erreurs sont affichées en entier. Touche une ligne pour copier le détail. Réessayer reprend les playlists contenant des échecs ; les fichiers déjà présents sont conservés." }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil), row = rows[indexPath.row]
        cell.textLabel?.text = row.0; cell.detailTextLabel?.text = row.1
        cell.textLabel?.numberOfLines = 0; cell.detailTextLabel?.numberOfLines = 0
        cell.imageView?.image = UIImage(systemName: "exclamationmark.circle"); cell.imageView?.tintColor = .systemOrange
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) { UIPasteboard.general.string = rows[indexPath.row].0 + "\n" + rows[indexPath.row].1; tableView.deselectRow(at: indexPath, animated: true) }
}

@MainActor
final class PWMetadataController: UITableViewController {
    private var observer: NSObjectProtocol?
    override func viewDidLoad() {
        super.viewDidLoad(); title = "Métadonnées"; overrideUserInterfaceStyle = .dark
        tableView.rowHeight = UITableView.automaticDimension; tableView.estimatedRowHeight = 90
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(close))
        observer = NotificationCenter.default.addObserver(forName: pwChanged, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.tableView.reloadData() } }
    }
    deinit { if let observer = observer { NotificationCenter.default.removeObserver(observer) } }
    @objc func close() { dismiss(animated: true) }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { 2 }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        "Tous les fichiers du catalogue sont traités. Spotify fournit en priorité l’album et la pochette. Apple iTunes puis MusicBrainz / Cover Art Archive complètent les données après vérification du titre, de l’artiste, de l’album et de la durée. Pochette, album et année restent inchangés sans résultat sûr. Les fichiers sont vérifiés avant remplacement, sans retélécharger l’audio. Garde l’app ouverte."
    }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.textLabel?.numberOfLines = 0; cell.detailTextLabel?.numberOfLines = 0
        if indexPath.row == 0 {
            cell.textLabel?.text = PWLocalLibrary.shared.metadataTask == nil ? "Mettre à jour les métadonnées" : "Arrêter la mise à jour"
            cell.imageView?.image = UIImage(systemName: "tag")
        } else { cell.textLabel?.text = PWLocalLibrary.shared.metadataStatus; cell.selectionStyle = .none }
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if indexPath.row == 0 { PWLocalLibrary.shared.updateMetadata(); tableView.reloadData() }
    }
}

private final class PWTrackMenuSelection: NSObject {
    let track: PWAudioTrack
    let destination: PWDownloadDestination?
    init(_ track: PWAudioTrack, destination: PWDownloadDestination?) { self.track = track; self.destination = destination }
}
