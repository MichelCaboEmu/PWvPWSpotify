import UIKit
import Network

@MainActor
enum PWOfflinePlaylist {
    private static var monitor: NWPathMonitor?
    private static var disconnected = false
    private static var networkAllowed = true
    static var enabled: Bool { disconnected || !networkAllowed }
    private static var views = NSHashTable<UIView>.weakObjects()

    static func start() {
        guard monitor == nil else { return }
        let path = NWPathMonitor(); monitor = path
        path.pathUpdateHandler = { value in
            let unavailable = value.status == .unsatisfied
            Task { @MainActor in
                let previous = enabled
                disconnected = unavailable
                if enabled != previous { refresh() }
            }
        }
        path.start(queue: DispatchQueue(label: "pw.offline.reachability"))
    }
    static func setNetworkAllowed(_ allowed: Bool) {
        let previous = enabled; networkAllowed = allowed
        if enabled != previous { refresh() }
    }
    static func observe(_ view: UIView) { views.add(view) }
    private static func refresh() {
        pwEvent("playlist_offline_state", details: ["offline":enabled, "network_allowed":networkAllowed])
        for view in views.allObjects where view.window != nil { view.setNeedsLayout() }
    }
    static func play(model: AnyObject, uri: String, title: String, selected: String?, presenter: UIViewController) -> Bool {
        guard enabled, PWDownloadRules.playlistPath(uri) != nil else { return false }
        _ = PWDownloadStore.shared
        let library = PWLocalLibrary.shared
        let snapshot = PWNativePlaylist.read(header: model, requestedURI: uri)
        let live = snapshot?.tracks ?? PWNativePlaylist.menuTracks(header: model, requestedURI: uri)
        let saved = library.catalog.playlists[uri]?.trackIDs ?? []
        let members = PWOfflinePlaylistRules.members(live: live.map(\.id), complete: snapshot?.complete == true, saved: saved)
        let files = Dictionary(members.compactMap { id -> (String, PWLocalEntry)? in
            library.available(id, playlist: uri).map { (id, $0) } ?? library.available(id).map { (id, $0) }
        }, uniquingKeysWith: { first, _ in first })
        guard let plan = PWOfflinePlaylistRules.plan(members: members, available: Set(files.keys), selected: selected) else {
            pwEvent("playlist_offline_unavailable", details: ["playlist":title, "selected":selected != nil, "members":members.count, "available":files.count])
            return true // handled: never fall through to online playback
        }
        // No playlist is written to the account; only this finite playback
        // request is adapted. Spotify keeps its native screen and queue.
        if selected == nil, PWNativePlayback.activePlaylist == uri,
           PWNativePlayback.state["context"] as? String == uri,
           (PWNativePlayback.state["uri"] as? String)?.hasPrefix("spotify:local:") == true,
           PWNativePlayback.handler?(["operation":"toggle"]) == true { return true }
        pwEvent("playlist_offline_play", details: ["playlist":title, "members":members.count, "available":plan.ids.count, "index":plan.index])
        PWNativePlayback.play(plan.ids.compactMap { files[$0] }, at: plan.index, title: title, from: presenter, playlistURI: uri)
        return true
    }
}

extension PWDownloadsBridge {
    @objc(startOfflinePlaylistBridge)
    static func startOfflinePlaylistBridge() { PWOfflinePlaylist.start() }
    @objc(nativeNetworkAllowed:)
    static func nativeNetworkAllowed(_ allowed: Bool) { PWOfflinePlaylist.setNetworkAllowed(allowed) }
    @objc(offlinePlaylistEnabled)
    static func offlinePlaylistEnabled() -> Bool { PWOfflinePlaylist.enabled }
    @objc(observeOfflinePlaylistRow:)
    static func observeOfflinePlaylistRow(_ view: UIView) { PWOfflinePlaylist.observe(view) }
    @objc(playOfflinePlaylistFrom:model:uri:title:selected:)
    static func playOfflinePlaylist(from presenter: UIViewController, model: AnyObject, uri: String, title: String, selected: String?) -> Bool {
        PWOfflinePlaylist.play(model: model, uri: uri, title: title, selected: selected, presenter: presenter)
    }
}
