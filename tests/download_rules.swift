import Foundation

@main
enum DownloadTests {
    static func main() {
        var count = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            count += 1
            if !value() { fatalError("FAIL: " + message) }
        }
        let id = "0123456789ABCDEFGHIJKL"
        check(PWDownloadRules.playlistPath("spotify:playlist:" + id) == "/v1/playlists/\(id)/items", "playlist URI")
        check(PWDownloadRules.playlistPath("spotify:user:name:playlist:" + id) != nil, "legacy playlist URI")
        check(PWDownloadRules.playlistPath("spotify:collection:tracks") == "/v1/me/tracks", "liked songs")
        check(PWDownloadRules.playlistPath("https://open.spotify.com/playlist/\(id)?si=abc") != nil, "public URL")
        check(PWDownloadRules.playlistPath("https://evil.com/playlist/" + id) == nil, "foreign URL")
        check(PWDownloadRules.playlistPath("spotify:playlist:../../secret") == nil, "path traversal")
        check(PWDownloadRules.playlistPath("spotify:album:" + id) == nil, "album is not playlist")
        // Mirrors the verified 9.1.78 field shape, including its loaded/unloaded enum.
        struct Artist { var name: String }
        struct Metadata { var name: String; var artists: [Artist]; var duration: Double }
        struct Item { var uri: URL; var metadata: Metadata; var isRecommendation = false }
        enum Entry { case loaded(Item), unloaded(Int) }
        struct ListMetadata { var isLoaded = true; var totalLength: UInt = 1 }
        struct TrackModel { var items: [Entry]; var unrangedLength = 1; var unfilteredLength = 1; var loadedItemCount = 1 }
        struct Entity { var entityURL: URL; var metadata = ListMetadata(); var tracks: TrackModel }
        struct Header { var entityModel: Entity }
        var itemMeta = Metadata(name: "La vérité", artists: [Artist(name: "Élodie")], duration: 200)
        let nativeTrack = Item(uri: URL(string: "spotify:track:" + id)!, metadata: itemMeta)
        let playlistURI = "spotify:playlist:" + id
        var header = Header(entityModel: Entity(entityURL: URL(string: playlistURI)!, tracks: TrackModel(items: [.loaded(nativeTrack)])))
        check(PWNativePlaylist.read(header: header, requestedURI: playlistURI)?.tracks.count == 1, "complete native list")
        header.entityModel.metadata.totalLength = 0
        var nativeEvents: [String: Int] = [:]
        let zeroHeader = PWNativePlaylist.read(header: header, requestedURI: playlistURI) { nativeEvents[$0] = $1 }
        check(zeroHeader?.complete == true && zeroHeader?.total == 1, "zero header count is not a filter")
        check(nativeEvents["native_header_count"] == 0 && nativeEvents["native_unfiltered_count"] == 1 && nativeEvents["native_loaded_count"] == 1, "diagnostics distinguish header and track counters")
        header.entityModel.tracks.loadedItemCount = 0
        check(PWNativePlaylist.read(header: header, requestedURI: playlistURI)?.complete == false, "zero header never allows a partial list")
        header.entityModel.tracks.loadedItemCount = 1
        header.entityModel.metadata.totalLength = 10
        check(PWNativePlaylist.read(header: header, requestedURI: playlistURI)?.complete == true, "stale header count does not invalidate coherent tracks snapshot")
        header.entityModel.metadata.totalLength = 1
        struct Model { var model: Entity }
        struct LiveHeader { var entityModel: Entity; var playlistModel: Model }
        var staleEntity = header.entityModel; staleEntity.tracks.loadedItemCount = 0
        var liveHeader = LiveHeader(entityModel: staleEntity, playlistModel: Model(model: header.entityModel))
        check(PWNativePlaylist.read(header: liveHeader, requestedURI: playlistURI)?.complete == true, "prefer current model over stale header snapshot")
        liveHeader.entityModel = header.entityModel; liveHeader.playlistModel.model = staleEntity
        check(PWNativePlaylist.read(header: liveHeader, requestedURI: playlistURI)?.complete == false, "do not substitute stale complete header for current partial model")
        liveHeader.playlistModel.model.entityURL = URL(string: "spotify:playlist:AAAAAAAAAAAAAAAAAAAAAA")!
        check(PWNativePlaylist.read(header: liveHeader, requestedURI: playlistURI) == nil, "live snapshot from another playlist rejected")
        header.entityModel.tracks.unfilteredLength = -1
        check(PWNativePlaylist.read(header: header, requestedURI: playlistURI)?.complete == false, "negative count rejected safely")
        header.entityModel.tracks.unfilteredLength = 1

        check(PWNativePlaylist.read(header: header, requestedURI: "spotify:playlist:AAAAAAAAAAAAAAAAAAAAAA") == nil, "reject another displayed playlist")
        header.entityModel.tracks.loadedItemCount = 0
        check(PWNativePlaylist.read(header: header, requestedURI: playlistURI)?.complete == false, "reject partially loaded native list")
        header.entityModel.tracks.loadedItemCount = 1; header.entityModel.tracks.unfilteredLength = 2
        check(PWNativePlaylist.read(header: header, requestedURI: playlistURI)?.complete == false, "reject filtered list")
        header.entityModel.tracks.unfilteredLength = 1; header.entityModel.tracks.items = [.unloaded(0)]
        check(PWNativePlaylist.read(header: header, requestedURI: playlistURI)?.tracks.isEmpty == true, "unloaded enum cannot masquerade as track")
        itemMeta.duration = .nan
        header.entityModel.tracks.items = [.loaded(Item(uri: nativeTrack.uri, metadata: itemMeta))]
        check(PWNativePlaylist.read(header: header, requestedURI: playlistURI) == nil, "reject invalid native duration")
        header.entityModel.tracks.items = [.loaded(Item(uri: URL(string: "spotify:episode:" + id)!, metadata: nativeTrack.metadata))]
        check(PWNativePlaylist.read(header: header, requestedURI: playlistURI)?.tracks.isEmpty == true, "skip episodes explicitly")
        header.entityModel.tracks.items = [.loaded(Item(uri: nativeTrack.uri, metadata: nativeTrack.metadata, isRecommendation: true))]
        check(PWNativePlaylist.read(header: header, requestedURI: playlistURI)?.complete == false, "reject injected recommendations")
        header.entityModel.metadata.isLoaded = false
        check(PWNativePlaylist.read(header: header, requestedURI: playlistURI) == nil, "unloaded metadata is not a snapshot")
        header.entityModel.tracks.items = [.loaded(nativeTrack), .unloaded(1),
            .loaded(Item(uri: nativeTrack.uri, metadata: nativeTrack.metadata, isRecommendation: true))]
        check(PWNativePlaylist.menuTracks(header: header, requestedURI: playlistURI).map(\.id) == [id], "row menu resolves loaded title despite partial neighbours and unloaded header")
        check(PWNativePlaylist.menuTracks(header: header, requestedURI: "spotify:playlist:AAAAAAAAAAAAAAAAAAAAAA").isEmpty, "row menu rejects a different playlist")
        header.entityModel.entityURL = URL(string: "spotify:collection:tracks")!
        check(PWNativePlaylist.menuTracks(header: header, requestedURI: "spotify:collection:tracks").count == 1, "liked-songs row menu")
        header.entityModel.entityURL = URL(string: playlistURI)!
        let track = PWAudioTrack(id: id, title: "La vérité", artist: "Élodie", duration: 200)
        let exact = PWAudioCandidate(id: "aB1_cD2-eF3", title: "La Verite", artist: "Elodie", duration: 202)
        check(PWDownloadRules.score(exact, for: track) != nil, "accent-insensitive match")
        var wrong = exact; wrong.title = "La Verite live"
        check(PWDownloadRules.score(wrong, for: track) == nil, "reject live variant")
        wrong = exact; wrong.artist = "Other artist"
        check(PWDownloadRules.score(wrong, for: track) == nil, "reject wrong artist")
        wrong = exact; wrong.title = "La Verite remix"
        check(PWDownloadRules.score(wrong, for: track) == nil, "reject remix")
        wrong = exact; wrong.duration = 30
        check(PWDownloadRules.score(wrong, for: track) == nil, "reject preview")
        wrong = exact; wrong.duration = 0
        check(PWDownloadRules.score(wrong, for: track) == nil, "reject missing duration")
        wrong = exact; wrong.title = "La Veritement"
        check(PWDownloadRules.score(wrong, for: track) == nil, "whole words")
        check(PWDownloadRules.seconds("3:20") == 200, "duration minutes")
        check(PWDownloadRules.seconds("1:02:03") == 3723, "duration hours")
        check(PWDownloadRules.seconds("LIVE") == 0, "live duration rejected")
        check(PWDownloadRules.mediaURL(URL(string: "https://rr1.googlevideo.com/videoplayback")!), "media host")
        check(!PWDownloadRules.mediaURL(URL(string: "https://googlevideo.com.evil.test/video")!), "media suffix attack")
        check(!PWDownloadRules.mediaURL(URL(string: "http://rr1.googlevideo.com/video")!), "cleartext rejected")
        check(!PWDownloadRules.mediaURL(URL(string: "https://user:pass@rr1.googlevideo.com/video")!), "credentials rejected")
        var unsafe = track; unsafe.title = "../../bad\nfile"; unsafe.artist = "a/b"
        check(!PWDownloadRules.filename(unsafe).contains("/"), "safe filename")
        let video: [String: Any] = ["contents": [["videoRenderer": ["videoId": exact.id,
            "title": ["runs": [["text": "La Verite"]]], "ownerText": ["simpleText": "Elodie"],
            "lengthText": ["simpleText": "3:22"]]]]]
        check(PWDownloadRules.candidates(video, music: false).count == 1, "video search parsing")
        check(PWDownloadRules.candidates(video, music: true).isEmpty, "no mixing of response shapes")
        let music: [String: Any] = ["musicResponsiveListItemRenderer": ["playlistItemData": ["videoId": exact.id],
            "flexColumns": [["musicResponsiveListItemFlexColumnRenderer": ["text": ["runs": [["text": "La Verite"]]]]],
                            ["musicResponsiveListItemFlexColumnRenderer": ["text": ["runs": [["text": "Elodie • Album • 3:22"]]]]]],
            "fixedColumns": [["musicResponsiveListItemFixedColumnRenderer": ["text": ["simpleText": "3:22"]]]]]]
        let found = PWDownloadRules.candidates(["contents": [music, music]], music: true)
        check(found.count == 1 && found[0].duration == 202, "music parsing and deduplication")
        check(PWDownloadRules.score(found[0], for: track) != nil, "music candidate matching")
        check(PWDownloadRules.candidates(["error": NSNull()], music: true).isEmpty, "malformed provider response")
        // Search responses do not necessarily contain playlistItemData. The play
        // endpoint and an extra flex column are used by current Music search rows.
        let searchRow: [String: Any] = ["musicResponsiveListItemRenderer": [
            "overlay": ["musicItemThumbnailOverlayRenderer": ["content": ["musicPlayButtonRenderer": [
                "playNavigationEndpoint": ["watchEndpoint": ["videoId": exact.id]]]]]],
            "flexColumns": [
                ["musicResponsiveListItemFlexColumnRenderer": ["text": ["runs": [["text": "La Verite"]]]]],
                ["musicResponsiveListItemFlexColumnRenderer": ["text": ["runs": [["text": "Elodie"]]]]],
                ["musicResponsiveListItemFlexColumnRenderer": ["text": ["runs": [["text": "Album • 3:22"]]]]]]]]
        let searched = PWDownloadRules.candidates(["contents": [searchRow]], music: true)
        check(searched.count == 1 && searched[0].id == exact.id && searched[0].duration == 202, "parse overlay ID and third duration column without playlistItemData")
        check(PWDownloadRules.score(searched[0], for: track) != nil, "match current Music search shape")
        let card: [String: Any] = ["musicCardShelfRenderer": ["onTap": ["watchEndpoint": ["videoId": exact.id]],
            "title": ["simpleText": "La Verite"], "subtitle": ["simpleText": "Elodie"], "contents": [searchRow]]]
        let deduplicated = PWDownloadRules.candidates(card, music: true)
        check(deduplicated.count == 1 && deduplicated[0].duration == 202, "prefer complete row over duplicate card without duration")
        check(PWDownloadRules.rendererCounts(card).contains("musicResponsiveListItemRenderer=1"), "report response shapes without dumping content")
        check(PWDownloadRules.seconds("3:99") == 0, "reject invalid seconds")
        check(PWDownloadRules.durationText("Elodie • Album • 3:22") == 202, "duration tolerates nonbreaking separators")
        var featured = track; featured.title += " (feat. Autre)"
        check(PWDownloadRules.score(exact, for: featured) != nil, "featured credits need not be repeated in candidate title")
        var apostrophe = track; apostrophe.title = "L’amour"
        var plainApostrophe = exact; plainApostrophe.title = "Lamour"
        check(PWDownloadRules.score(plainApostrophe, for: apostrophe) != nil, "normalize apostrophe spelling")
        var mismatch = exact; mismatch.duration = .nan
        check(PWDownloadRules.rejection(mismatch, for: track) == "missing_duration", "non-finite metadata rejected without integer conversion")
        mismatch = exact; mismatch.title += " live"
        check(PWDownloadRules.rejection(mismatch, for: track) == "version", "diagnose different recording")
        mismatch = exact; mismatch.artist = "Another artist"
        check(PWDownloadRules.rejection(mismatch, for: track) == "artist", "diagnose wrong artist")
        let secretText = #"Failed https://media.test/audio?sig=secret Authorization: Bearer abc SOCS=private {"access_token":"hidden"}"#
        let sanitized = PWDownloadLog.clean(secretText)
        for secret in ["media.test", "sig=secret", "abc", "private", "hidden"] {
            check(!sanitized.contains(secret), "redact URL, bearer and preference values")
        }
        check(PWDownloadLog.clean("La vérité — Élodie") == "La vérité — Élodie", "retain useful song metadata")
        check(PWDownloadLog.clean(String(repeating: "a", count: 2000)).count == 800, "bound diagnostic messages")
        let diagnostic = PWDownloadLog.error(NSError(domain: "outer", code: 7, userInfo: [
            NSLocalizedDescriptionKey: "Search failed", NSUnderlyingErrorKey: NSError(domain: NSURLErrorDomain, code: -1009)]))
        check(diagnostic["error_domain"] as? String == "outer" && diagnostic["underlying_code"] as? Int == -1009, "preserve real error and underlying cause")
        check(PWDownloadLog.fields(["authorization": "secret", "duration": Double.nan]).isEmpty, "omit sensitive keys and non-JSON numbers")
        header.entityModel.metadata.isLoaded = true
        header.entityModel.tracks.items = Array(repeating: .unloaded(0), count: 208)
        header.entityModel.tracks.loadedItemCount = 119
        header.entityModel.tracks.unrangedLength = 208
        header.entityModel.tracks.unfilteredLength = 209
        var partialEvents: [String] = []
        let partial = PWNativePlaylist.read(header: header, requestedURI: playlistURI) { partialEvents.append($0); _ = $1 }
        check(partial?.complete == false && partial?.problem?.contains("119") == true && partial?.problem?.contains("208") == true, "explain device's actual loading deficit")
        check(partialEvents.contains("native_list_partial") && !partialEvents.contains("native_list_filtered"), "partial loading is not reported solely as a filter")
        header.entityModel.tracks.items = Array(repeating: .loaded(nativeTrack), count: 208)
        header.entityModel.tracks.loadedItemCount = 208
        let available = PWNativePlaylist.read(header: header, requestedURI: playlistURI)
        check(available?.complete == false && available?.tracks.count == 208, "208 of 209: retain verified rows without claiming completeness")
        check(available?.availableRows == 208 && available?.total == 209, "preserve missing row count for explicit choice")
        header.entityModel.tracks.items = Array(repeating: .loaded(nativeTrack), count: 119) + Array(repeating: .unloaded(0), count: 89)
        header.entityModel.tracks.loadedItemCount = 119
        let loadedSubset = PWNativePlaylist.read(header: header, requestedURI: playlistURI)
        check(loadedSubset?.tracks.count == 119 && loadedSubset?.complete == false, "119 of 208: only offer genuinely loaded rows")
        header.entityModel.tracks.loadedItemCount = 120
        check(PWNativePlaylist.read(header: header, requestedURI: playlistURI)?.tracks.isEmpty == true, "inconsistent loaded count is never offered")
        let pnl = PWAudioTrack(id: id, title: "91's", artist: "PNL", duration: 234)
        let searches = PWSearchAttempt.plan(pnl, music: true)
        let body = try! JSONSerialization.data(withJSONObject: ["query": searches[0].query])
        let roundTrip = try! JSONSerialization.jsonObject(with: body) as! [String: String]
        check(roundTrip["query"] == "91's PNL", "apostrophe survives JSON search encoding")
        check(searches.map { $0.mode } == ["songs_exact", "videos_exact", "all_exact"], "bounded fallback widens Music results without changing supplier")
        let apostropheMatch = PWAudioCandidate(id: exact.id, title: "91’s", artist: "PNL", duration: 238)
        check(PWDownloadRules.score(apostropheMatch, for: pnl) != nil, "device's 91's match is accepted with curly apostrophe too")
        let auDD = PWAudioTrack(id: id, title: "Au DD", artist: "PNL", duration: 247)
        check(PWDownloadRules.score(apostropheMatch, for: auDD) == nil, "wider search never substitutes 91's for Au DD")
        let item: [String: Any] = ["type": "track", "id": id, "name": "La vérité", "artists": [["name": "Élodie"]], "duration_ms": 200000.0]
        check(PWDownloadRules.tracks([["item": item]]).count == 1, "new playlist item shape")
        check(PWDownloadRules.tracks([["track": item]]).count == 1, "legacy playlist item shape")
        check(PWDownloadRules.tracks([["track": NSNull()]]).isEmpty, "unavailable track")
        var local = item; local["is_local"] = true
        check(PWDownloadRules.tracks([["track": local]]).isEmpty, "local track excluded")
        var episode = item; episode["type"] = "episode"
        check(PWDownloadRules.tracks([["item": episode]]).isEmpty, "podcast excluded")
        let config: [String: Any] = ["INNERTUBE_CONTEXT": ["client": ["clientName": "WEB", "clientVersion": "2.20260928.01.00", "note": "A } brace and \"quote\""]]]
        let encoded = String(data: try! JSONSerialization.data(withJSONObject: config), encoding: .utf8)!
        let html = "<script>ytcfg.set({\"OTHER\":1});ytcfg.set(" + encoded + ");</script>"
        check(PWYouTubeSearchConfig.parse(html, music: false)?.version == "2.20260928.01.00", "current client config with escaped strings")
        check(PWYouTubeSearchConfig.parse(html, music: false)?.clientNumber == "1", "YouTube client header")
        check(PWYouTubeSearchConfig.parse(html, music: true) == nil, "reject wrong service config")
        let musicHTML = html.replacingOccurrences(of: "WEB", with: "WEB_REMIX")
        check(PWYouTubeSearchConfig.parse(musicHTML, music: true)?.clientNumber == "67", "Music client header")
        check(PWYouTubeSearchConfig.parse("<html>Sign in</html>", music: false) == nil, "do not treat a sign-in wall as config")
        check(PWYouTubeSearchConfig.parse("ytcfg.set({broken)", music: false) == nil, "reject partial config")
        check(PWDownloadHTTPError(stage: .spotifyItems, status: 404).localizedDescription.contains("n’a pas démarré"), "attribute playlist 404 to Spotify before YouTube")
        check(PWDownloadHTTPError(stage: .youtubeMusicSearch, status: 404).localizedDescription.contains("YouTube Music"), "attribute Music 404 correctly")
        check(PWDownloadHTTPError(stage: .youtubeSearch, status: 401).localizedDescription.contains("YouTube"), "YouTube error never asks to renew Spotify session")

        check(PWYouTubeAccess.redirectAllowed(originHost: "music.youtube.com", to: URL(string: "https://www.youtube.com/")!), "follow public YouTube canonical redirect")
        check(PWYouTubeAccess.redirectAllowed(originHost: "www.youtube.com", to: URL(string: "https://m.youtube.com/")!), "follow public mobile redirect")
        check(!PWYouTubeAccess.redirectAllowed(originHost: "music.youtube.com", to: URL(string: "https://consent.youtube.com/m")!), "consent requires user choice instead of an API fetch")
        check(PWYouTubeAccess.consentURL(URL(string: "https://consent.youtube.com/m?continue=x")!), "recognize consent destination")
        for address in ["http://consent.youtube.com/m", "https://consent.youtube.com.evil.test/m", "https://user:pass@consent.youtube.com/m", "https://consent.youtube.com:444/m"] {
            check(!PWYouTubeAccess.consentURL(URL(string: address)!), "reject unsafe consent destination")
        }
        check(!PWYouTubeAccess.redirectAllowed(originHost: "api.spotify.com", to: URL(string: "https://www.youtube.com/")!), "Spotify redirect isolation")
        check(!PWYouTubeAccess.redirectAllowed(originHost: "www.youtube.com", to: URL(string: "https://accounts.google.com/")!), "do not silently enter account sign-in")
        check(!PWYouTubeAccess.redirectAllowed(originHost: "music.youtube.com", to: URL(string: "https://youtube.com.evil.test/")!), "reject foreign redirect")
        check(PWYouTubeAccess.redirectAllowed(originHost: nil, to: URL(string: "https://rr1.googlevideo.com/videoplayback")!), "preserve audio redirect policy")
        let preferenceSuite = "PWDownloadTests-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: preferenceSuite)!
        defer { preferences.removePersistentDomain(forName: preferenceSuite) }
        let now = Date(timeIntervalSince1970: 1800000000)
        func cookie(_ name: String, _ value: String, domain: String = ".youtube.com", expires: Date? = nil) -> HTTPCookie {
            var properties: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value, .domain: domain, .path: "/"]
            if let expires = expires { properties[.expires] = expires }
            return HTTPCookie(properties: properties)!
        }
        let choice = cookie("SOCS", "user-choice", expires: now.addingTimeInterval(3600))
        check(PWYouTubeAccess.save([choice, cookie("SID", "account-secret"), cookie("VISITOR_INFO1_LIVE", "visitor")], defaults: preferences, now: now), "save actual preference only")
        check(PWYouTubeAccess.cookieHeader(for: URL(string: "https://music.youtube.com/")!, defaults: preferences, now: now) == "SOCS=user-choice", "copy no account or visitor cookies")
        for address in ["https://api.spotify.com/", "https://rr1.googlevideo.com/", "https://consent.youtube.com/m", "http://www.youtube.com/"] {
            check(PWYouTubeAccess.cookieHeader(for: URL(string: address)!, defaults: preferences, now: now) == nil, "preference never leaves public YouTube")
        }
        check(!PWYouTubeAccess.preference(cookie("CONSENT", "PENDING+123"), now: now), "pending choice is not a completed choice")
        check(PWYouTubeAccess.consentState(cookie("CONSENT", "PENDING+123"), now: now), "pending provider state can bootstrap the temporary consent page")
        let stateHeaders = ["Set-Cookie": "SOCS=provider-state; Domain=.youtube.com; Path=/; Secure; HttpOnly"]
        let states = PWYouTubeAccess.consentState(headers: stateHeaders, from: URL(string: "https://music.youtube.com/")!, now: now)
        check(states.count == 1 && states[0].value == "provider-state", "carry original redirect state without generating a consent choice")
        for name in ["SID", "YSC", "VISITOR_INFO1_LIVE", "__Secure-YENID"] {
            check(PWYouTubeAccess.consentState(headers: ["Set-Cookie": "\(name)=private; Domain=.youtube.com; Path=/; Secure"], from: URL(string: "https://music.youtube.com/")!, now: now).isEmpty, "never bootstrap account or visitor state")
        }
        check(PWYouTubeAccess.consentState(headers: stateHeaders, from: URL(string: "https://api.spotify.com/")!, now: now).isEmpty, "accept consent state only from public YouTube response")
        check(!PWYouTubeAccess.preference(cookie("SOCS", "x", domain: ".google.com"), now: now), "reject foreign cookie")
        check(!PWYouTubeAccess.preference(cookie("SOCS", "x", expires: now.addingTimeInterval(-1)), now: now), "reject expired preference")
        check(PWYouTubeAccess.cookieHeader(for: URL(string: "https://www.youtube.com/")!, defaults: preferences, now: now.addingTimeInterval(3601)) == nil, "saved preference expires")
        let target = URL(string: "https://consent.youtube.com/m?continue=https%3A%2F%2Fmusic.youtube.com%2F&hl=fr")!
        let consent = PWYouTubeConsentRequired(source: 0, target: target)
        check(consent.target == target, "retain full provider consent redirect instead of opening a fresh homepage")
        check(consent.localizedDescription.contains("Vérifier l’accès YouTube"), "give actionable consent message")
        check(PWYouTubeAccess.homepage(source: consent.source).host == "music.youtube.com", "verify the originally selected service")
        check(PWYouTubeAccess.homepage(source: 1).host == "www.youtube.com", "verify video service separately")
        check(!PWYouTubeAccess.save([], defaults: preferences, now: now), "do not fabricate preferences when browser shows no choice")
        print("PASS: \(count) download rules")
    }
}
