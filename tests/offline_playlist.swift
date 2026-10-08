import Foundation

@main struct OfflinePlaylistTests {
    static func main() {
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            guard value() else { fatalError(message) }; checks += 1
        }
        let downloaded: Set<String> = ["avion1", "avion3", "liked1", "shared", "other"]
        let avion = ["avion1", "avion2", "avion3", "shared"]
        let liked = ["liked1", "liked2", "shared"]
        check(PWOfflinePlaylistRules.plan(members: avion, available: downloaded, selected: nil)?.ids == ["avion1", "avion3", "shared"], "Avion does not contain other playlists' downloads")
        check(PWOfflinePlaylistRules.plan(members: liked, available: downloaded, selected: nil)?.ids == ["liked1", "shared"], "Liked songs are independent")
        check(PWOfflinePlaylistRules.plan(members: avion, available: downloaded, selected: "avion3")?.index == 1, "selected index is remapped after filtering")
        check(PWOfflinePlaylistRules.plan(members: avion, available: downloaded, selected: "avion2") == nil, "unavailable selection never plays a different title")
        check(PWOfflinePlaylistRules.plan(members: avion, available: downloaded, selected: "liked1") == nil, "selected title must belong to this playlist")
        check(PWOfflinePlaylistRules.plan(members: avion, available: [], selected: nil) == nil, "no available files means no playback")
        check(PWOfflinePlaylistRules.plan(members: [], available: downloaded, selected: nil) == nil, "empty playlist never becomes whole library")
        check(PWOfflinePlaylistRules.plan(members: ["shared", "avion1", "shared"], available: downloaded, selected: nil)?.ids == ["shared", "avion1", "shared"], "preserve duplicate membership and order")
        check(PWOfflinePlaylistRules.members(live: ["avion3", "avion1"], complete: true, saved: avion) == ["avion3", "avion1"], "complete current snapshot reflects removals and reorder")
        check(PWOfflinePlaylistRules.members(live: [], complete: true, saved: avion).isEmpty, "empty complete snapshot removes old membership")
        check(PWOfflinePlaylistRules.members(live: ["avion1"], complete: false, saved: avion) == avion, "partial load preserves cached neighbours")
        check(PWOfflinePlaylistRules.members(live: ["avion1", "new"], complete: false, saved: avion) == avion + ["new"], "new verified members appended once")
        check(PWOfflinePlaylistRules.members(live: ["liked1"], complete: false, saved: []) == ["liked1"], "without cache use only loaded playlist")
        print("Offline playlist PASS: \(checks) checks")
    }
}
