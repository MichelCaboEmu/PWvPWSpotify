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
    static func read(header: Any, requestedURI: String, report: (String, Int) -> Void = { _, _ in }) -> PWNativePlaylist? {
        // The header keeps its own snapshot. Prefer the underlying playlist model
        // when available; both field paths were verified in 9.1.78.
        let live = field(header, "playlistModel").flatMap { field($0, "model") }
        report("native_snapshot_source", live == nil ? 0 : 1)
        guard let entity = live ?? field(header, "entityModel"),
              let entityURI = uri(field(entity, "entityURL")),
              let path = PWDownloadRules.playlistPath(requestedURI),
              PWDownloadRules.playlistPath(entityURI) == path else {
            report("native_schema_unavailable", 1); return nil
        }
        guard let metadata = field(entity, "metadata"), field(metadata, "isLoaded") as? Bool == true,
              let model = field(entity, "tracks"),
              let unfiltered = integer(field(model, "unfilteredLength")),
              let unranged = integer(field(model, "unrangedLength")),
              let loaded = integer(field(model, "loadedItemCount")),
              let items = field(model, "items") as? [Any] else {
            report("native_schema_unavailable", 2); return nil
        }
        let headerTotal = integer(field(metadata, "totalLength")) ?? -1
        report("native_header_count", headerTotal)
        report("native_unfiltered_count", unfiltered)
        report("native_unranged_count", unranged)
        report("native_loaded_count", loaded)
        report("native_item_count", items.count)
        // totalLength can be zero/stale even with loaded metadata (device logs).
        // It is not proof of a filter. Completeness belongs to the tracks snapshot.
        let total = unfiltered
        guard (0...10000).contains(total), (0...total).contains(unranged), (0...total).contains(loaded), items.count <= 10000 else {
            report("native_count_inconsistent", 0)
            return PWNativePlaylist(tracks: [], total: max(0, total), problem: "Les compteurs de la liste Spotify sont incohérents ou dépassent 10 000 éléments. Aucun téléchargement n’a démarré. Exporte les logs pour le diagnostic.")
        }
        if headerTotal != total { report("native_header_count_ignored", headerTotal) }
        // Partial loading and filtered/hidden items are independent conditions.
        // Report the loading deficit first instead of blaming filters alone.
        guard items.count == unranged, loaded == unranged else {
            report("native_list_partial", 0)
            return PWNativePlaylist(tracks: [], total: total, problem: "Spotify n’a chargé que \(loaded) éléments sur \(unranged) affichés (\(total) annoncés au total). Fais défiler la playlist pour charger ses titres, puis réessaie. Si les compteurs diffèrent encore, vérifie la recherche, les filtres et les titres indisponibles. Aucun téléchargement partiel n’a été lancé.")
        }
        guard unfiltered == unranged else {
            report("native_list_filtered", 0)
            return PWNativePlaylist(tracks: [], total: total, problem: "La liste affichée contient \(unranged) éléments sur \(total) annoncés. Vérifie la recherche, les filtres et les titres masqués ou indisponibles, puis réessaie la flèche. La liste complète n’est pas encore accessible.")
        }
        var result: [PWAudioTrack] = []
        for item in items {
            guard let track = field(item, "loaded"), let link = uri(field(track, "uri")),
                  let meta = field(track, "metadata"), let recommendation = field(track, "isRecommendation") as? Bool else { report("native_item_unavailable", 1); return nil }
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
                  duration.isFinite, duration > 0, duration <= 86400 else { report("native_item_unavailable", 2); return nil }
            result.append(PWAudioTrack(id: id, title: title, artist: artist, duration: duration))
        }
        return PWNativePlaylist(tracks: result, total: total, problem: nil)
    }
}
