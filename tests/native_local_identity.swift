import Foundation

@main struct NativeLocalIdentityTests {
    static func main() {
        var checks = 0
        func check(_ pass: @autoclosure () -> Bool, _ label: String) {
            guard pass() else { fatalError(label) }; checks += 1
        }
        let uri = PWNativeLocalIdentity.uri(artist: "David Wise", album: "Donkey Kong Country: Tropical Freeze", title: "Snomads Island", duration: 127)
        check(uri == "spotify:local:David+Wise:Donkey+Kong+Country%3A+Tropical+Freeze:Snomads+Island:127", "documented Spotify example")
        check(PWNativeLocalIdentity.uri(artist: "PNL", album: "Deux frères", title: "91's", duration: 238.9) == "spotify:local:PNL:Deux+fr%C3%A8res:91%27s:238", "apostrophe, UTF8 and actual audio duration")
        check(PWNativeLocalIdentity.uri(artist: "A+B", album: "% :", title: "a/b?", duration: 12) == "spotify:local:A%2BB:%25+%3A:a%2Fb%3F:12", "reserved URI characters")
        for duration in [Double.nan, Double.infinity, -1, 0, 86400] {
            check(PWNativeLocalIdentity.uri(artist: "A", album: "", title: "Song", duration: duration) == nil, "invalid duration")
        }
        let tracks: [[String: Any]] = [["uri":uri!], ["uri":"spotify:local:PNL::91%27s:238"]]
        let request = PWNativeLocalIdentity.context(tracks: tracks, title: "Avion", index: 1)!
        let context = request["context"] as! [String: Any]
        let pages = context["pages"] as! [[String: Any]]
        check(pages.count == 1 && pages[0]["next_page_url"] == nil, "finite local queue")
        check((pages[0]["tracks"] as! [[String: Any]])[1]["uri"] as? String == tracks[1]["uri"] as? String, "queue order")
        let options = request["options"] as! [String: Any]
        check((options["skip_to"] as! [String: Int])["track_index"] == 1, "selected start index")
        check(options["always_play_something"] as? Bool == false, "no streaming fallback")
        check(PWNativeLocalIdentity.context(tracks: [["uri":"spotify:track:abc"]], title: "No", index: 0) == nil, "reject online URI")
        check(PWNativeLocalIdentity.context(tracks: tracks, title: "No", index: 2) == nil, "reject out of bounds selection")
        check(PWNativeLocalIdentity.context(tracks: [], title: "No", index: 0) == nil, "reject empty context")
        print("Native local identity PASS: \(checks) checks")
    }
}
