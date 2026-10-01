import Foundation

@main struct CatalogTests {
    static func main() async throws {
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
        var folders = PWPlaylistFolderIndex()
        precondition(folders.reserve(uri: "one", title: "Avion", occupied: []) == "Avion")
        folders.playlists["one"]?.tracks[one.id] = "PNL - 91's.m4a"
        var restored = try JSONDecoder().decode(PWPlaylistFolderIndex.self, from: JSONEncoder().encode(folders))
        precondition(restored.reserve(uri: "one", title: "Avion", occupied: ["Avion"]) == "Avion", "same playlist survives a new queue")
        precondition(restored.playlists["one"]?.tracks[one.id] == "PNL - 91's.m4a")
        precondition(restored.reserve(uri: "two", title: "Avion", occupied: ["Avion"]) == "Avion (2)", "different playlist does not overwrite")
        precondition(PWPlaylistFolderIndex.name("../Avion\\été:\n") == "Avion été")
        var albumTrack = one; albumTrack.album = "Deux frères"
        let wrong: [String: Any] = ["trackName": "91's", "artistName": "PNL", "trackTimeMillis": 234000.0, "collectionName": "Hits 2026"]
        let right: [String: Any] = ["trackName": "91’s", "artistName": "PNL", "trackTimeMillis": 238000.0, "collectionName": "Deux frères"]
        precondition(PWMetadataRules.appleMatch([wrong, right], track: albumTrack)?["collectionName"] as? String == "Deux frères", "album beats closest duration")
        precondition(PWMetadataRules.appleMatch([wrong], track: albumTrack) == nil, "never replace the original cover with a compilation")
        precondition(PWMetadataRules.appleMatch([wrong, right], track: one) == nil, "ambiguous album preserves artwork")
        precondition(PWMetadataRules.artworkURL("spotify:image:" + String(repeating: "a", count: 40)) == "https://i.scdn.co/image/" + String(repeating: "a", count: 40))
        precondition(PWMetadataRules.artworkURL("https://i.scdn.co.evil.example/x") == nil)
        enum RetryFailure: Error { case forbidden, missing }
        var attempts: [Int] = [], waits = 0, fallback = 0
        let answer = try await PWMediaRetry.run(operation: { n in attempts.append(n); if n == 1 { throw RetryFailure.forbidden }; return "ok" }, forbidden: { ($0 as? RetryFailure) == .forbidden }, waiting: { waits += 1 }, sleep: {})
        precondition(answer == "ok" && attempts == [1, 2] && waits == 1 && fallback == 0)
        attempts = []; waits = 0
        do { let _: Int = try await PWMediaRetry.run(operation: { n in attempts.append(n); throw RetryFailure.forbidden }, forbidden: { ($0 as? RetryFailure) == .forbidden }, waiting: { waits += 1 }, sleep: {}); fatalError("expected failure") }
        catch { fallback += 1 }
        precondition(attempts == [1, 2] && waits == 1 && fallback == 1, "fallback only after second failure")
        attempts = []; waits = 0
        do { let _: Int = try await PWMediaRetry.run(operation: { n in attempts.append(n); throw RetryFailure.missing }, forbidden: { ($0 as? RetryFailure) == .forbidden }, waiting: { waits += 1 }, sleep: {}); fatalError("expected failure") } catch {}
        precondition(attempts == [1] && waits == 0, "non-403 has no delayed retry")
        attempts = []
        do { let _: Int = try await PWMediaRetry.run(operation: { n in attempts.append(n); throw RetryFailure.forbidden }, forbidden: { _ in true }, waiting: {}, sleep: { throw CancellationError() }); fatalError("expected cancellation") } catch is CancellationError {} catch { fatalError("wrong cancellation") }
        precondition(attempts == [1], "cancelling delay prevents second transfer")
        print("Library catalog: persistence, migration, incremental membership, filenames and provider matching passed")
    }
}
