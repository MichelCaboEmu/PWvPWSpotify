import Foundation

// Read-only Swift reflection of 9.1.78's displayed playlist model. Field names,
// enum cases and types were checked in that executable's Swift field metadata.
// No guessed selectors, ivar offsets, session changes or network requests.
struct PWNativePlaylist {
    let tracks: [PWAudioTrack]
    let total: Int
    let problem: String?
    var complete: Bool { problem == nil }

    static func field(_ value: Any, _ name: String) -> Any? {
        Mirror(reflecting: value).children.first { $0.label == name }?.value
    }
    static func uri(_ value: Any?) -> String? {
        if let url = value as? URL { return url.absoluteString }
        return value as? String
    }
    static func integer(_ value: Any?) -> Int? {
        if let n = value as? Int { return n }
        if let n = value as? UInt, n <= UInt(Int.max) { return Int(n) }
        return nil
    }
    static func read(header: Any, requestedURI: String) -> PWNativePlaylist? {
        guard let entity = field(header, "entityModel"),
              let entityURI = uri(field(entity, "entityURL")),
              let path = PWDownloadRules.playlistPath(requestedURI),
              PWDownloadRules.playlistPath(entityURI) == path,
              let metadata = field(entity, "metadata"), field(metadata, "isLoaded") as? Bool == true,
              let total = integer(field(metadata, "totalLength")), (0...10000).contains(total),
              let model = field(entity, "tracks"),
              let unfiltered = integer(field(model, "unfilteredLength")),
              let unranged = integer(field(model, "unrangedLength")),
              let loaded = integer(field(model, "loadedItemCount")),
              let items = field(model, "items") as? [Any] else { return nil }
        guard total == unfiltered, unfiltered == unranged else {
            return PWNativePlaylist(tracks: [], total: total, problem: "Désactive la recherche et les filtres de la playlist, puis réessaie la flèche.")
        }
        guard items.count == total, loaded == total else {
            return PWNativePlaylist(tracks: [], total: total, problem: "Spotify n’a chargé que \(loaded) éléments sur \(total). Fais défiler la playlist pour charger ses titres, puis réessaie. Aucun téléchargement partiel n’a été lancé.")
        }
        var result: [PWAudioTrack] = []
        for item in items {
            guard let track = field(item, "loaded"), let link = uri(field(track, "uri")),
                  let meta = field(track, "metadata"), let recommendation = field(track, "isRecommendation") as? Bool else { return nil }
            if recommendation { return PWNativePlaylist(tracks: [], total: total, problem: "Désactive les recommandations et les filtres de la playlist, puis réessaie.") }
            // Explicitly skip episodes and local files; a malformed music track
            // invalidates the snapshot instead of silently dropping a song.
            if link.hasPrefix("spotify:episode:") || link.hasPrefix("spotify:local:") { continue }
            guard link.hasPrefix("spotify:track:"), let id = link.split(separator: ":").last.map(String.init),
                  PWDownloadRules.identifier(id, length: 22),
                  let title = field(meta, "name") as? String, !title.isEmpty,
                  let artists = field(meta, "artists") as? [Any],
                  let artist = artists.first.flatMap({ field($0, "name") as? String }), !artist.isEmpty,
                  let duration = field(meta, "duration") as? Double,
                  duration.isFinite, duration > 0, duration <= 86400 else { return nil }
            result.append(PWAudioTrack(id: id, title: title, artist: artist, duration: duration))
        }
        return PWNativePlaylist(tracks: result, total: total, problem: nil)
    }
}
