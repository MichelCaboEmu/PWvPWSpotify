import Foundation

// Read-only Swift reflection of 9.1.78's displayed playlist model. Field names,
// enum cases and types were checked in that executable's Swift field metadata.
// No guessed selectors, ivar offsets, session changes or network requests.
struct PWNativePlaylist {
    let tracks: [PWAudioTrack]
    let total: Int
    let problem: String?
    var availableRows = 0
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
        var problem: String?
        if items.count != unranged || loaded != unranged {
            report("native_list_partial", 0)
            problem = "Spotify a chargé \(loaded) éléments sur \(unranged) affichés (\(total) annoncés). Fais défiler la playlist puis réessaie pour charger davantage de titres, ou choisis les morceaux disponibles ci-dessous."
        } else if unfiltered != unranged {
            report("native_list_filtered", 0)
            problem = "Les \(unranged) éléments affichés sont tous chargés, sur \(total) annoncés par Spotify. La différence peut venir de filtres ou de titres masqués ou indisponibles. Tu peux télécharger les morceaux disponibles ci-dessous."
        }
        var result: [PWAudioTrack] = []
        var availableRows = 0
        for item in items {
            if field(item, "unloaded") != nil { continue }
            guard let track = field(item, "loaded"), let link = uri(field(track, "uri")),
                  let meta = field(track, "metadata"), let recommendation = field(track, "isRecommendation") as? Bool else { report("native_item_unavailable", 1); return nil }
            availableRows += 1
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
            let covers = field(meta, "albumCovers") as? [String: Any] ?? field(meta, "covers") as? [String: Any] ?? [:]
            let cover = covers.sorted { $0.key > $1.key }.compactMap { uri($0.value) }.compactMap(PWMetadataRules.artworkURL).first
            result.append(PWAudioTrack(id: id, title: title, artist: artist, duration: duration,
                album: field(meta, "albumName") as? String, artworkURL: cover))
        }
        // A count mismatch cannot be used to invent or silently omit tracks.
        // Keep the problem for display, but expose verified rows for an explicit choice.
        guard availableRows == loaded else {
            return PWNativePlaylist(tracks: [], total: total, problem: problem ?? "Le contenu et les compteurs Spotify ne correspondent pas. Réessaie après le chargement de la playlist.")
        }
        return PWNativePlaylist(tracks: result, total: total, problem: problem, availableRows: availableRows)
    }
}
