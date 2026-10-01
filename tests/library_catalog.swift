import Foundation

@main struct CatalogTests {
    static func main() throws {
        let one = PWAudioTrack(id: "1234567890123456789012", title: "91's", artist: "PNL", duration: 234)
        let two = PWAudioTrack(id: "2234567890123456789012", title: "Nouveau", artist: "PNL", duration: 180)
        var catalog = PWLibraryCatalog()
        catalog.remember(uri: "liked", title: "Titres likés", tracks: [one, one], complete: true)
        precondition(catalog.playlists["liked"]?.trackIDs == [one.id], "same ID appears once")
        catalog.entries[one.id] = PWLocalEntry(track: one, directory: "Playlist-old", filename: "PNL - 91's [1234567890123456789012].m4a")
        catalog.remember(uri: "liked", title: "Titres likés", tracks: [one, two], complete: true)
        precondition(catalog.playlists["liked"]?.trackIDs.count == 2)
        precondition(catalog.playlists["liked"]?.trackIDs.filter { catalog.entries[$0] == nil } == [two.id], "incremental identity")
        catalog.remember(uri: "other", title: "Autre", tracks: [one], complete: true)
        precondition(catalog.entries.count == 1, "global reuse across playlists")
        catalog.remember(uri: "liked", title: "Titres likés", tracks: [two], complete: false)
        precondition(Set(catalog.playlists["liked"]!.trackIDs) == Set([one.id, two.id]), "partial snapshots never erase membership")
        catalog.remember(uri: "liked", title: "Titres likés", tracks: [two], complete: true)
        precondition(catalog.playlists["liked"]?.trackIDs == [two.id])
        precondition(catalog.entries[one.id] != nil, "playlist refresh does not delete audio")
        let decoded = try JSONDecoder().decode(PWLibraryCatalog.self, from: JSONEncoder().encode(catalog))
        precondition(decoded.entries[one.id]?.filename.contains("[") == true, "old path retained for migration")
        precondition(PWDownloadRules.filename(one) == "PNL - 91's.m4a", "no random ID in visible filename")
        for unsafe in ["..", ".", "", "../x", "a/b", "a\\b"] { precondition(!PWLibraryCatalog.safeComponent(unsafe)) }
        precondition(PWLibraryCatalog.safeComponent("PNL - 91's (2).m4a"))
        let candidate = PWAudioCandidate(id: "soundcloud:tracks:123", title: "91's", artist: "PNL", duration: 236)
        precondition(PWDownloadRules.rejection(candidate, for: one) == "identifier")
        precondition(PWDownloadRules.rejection(candidate, for: one, requireYouTubeID: false) == nil)
        let remix = PWAudioCandidate(id: "123", title: "91's remix", artist: "PNL", duration: 236)
        precondition(PWDownloadRules.rejection(remix, for: one, requireYouTubeID: false) == "version")
        precondition(!PWDownloadLog.clean("OAuth secret-token").contains("secret-token"))
        print("Library catalog: persistence, migration, incremental membership, filenames and provider matching passed")
    }
}
