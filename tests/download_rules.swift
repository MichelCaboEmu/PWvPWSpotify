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
        let item: [String: Any] = ["type": "track", "id": id, "name": "La vérité", "artists": [["name": "Élodie"]], "duration_ms": 200000.0]
        check(PWDownloadRules.tracks([["item": item]]).count == 1, "new playlist item shape")
        check(PWDownloadRules.tracks([["track": item]]).count == 1, "legacy playlist item shape")
        check(PWDownloadRules.tracks([["track": NSNull()]]).isEmpty, "unavailable track")
        var local = item; local["is_local"] = true
        check(PWDownloadRules.tracks([["track": local]]).isEmpty, "local track excluded")
        var episode = item; episode["type"] = "episode"
        check(PWDownloadRules.tracks([["item": episode]]).isEmpty, "podcast excluded")
        print("PASS: \(count) download rules")
    }
}
