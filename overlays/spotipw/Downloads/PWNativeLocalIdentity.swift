import Foundation

// Spotify's documented local URI format. Use the FILE's tags and actual duration,
// never catalogue duration (a downloaded recording can differ by seconds).
enum PWNativeLocalIdentity {
    // NSURL(BetamaxSDK).spt_localFileImagePath decodes URI component 2.
    // This is an audio-file path; the native loader extracts its embedded art.
    static func artworkURL(file: URL) -> URL? {
        guard file.isFileURL, file.path.hasPrefix("/") else { return nil }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        guard let path = file.path.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "spotify:localfileimage:" + path)
    }
    static func uri(artist: String, album: String, title: String, duration: Double) -> String? {
        guard duration.isFinite, duration > 0, duration < 86400, !title.isEmpty else { return nil }
        func escape(_ text: String) -> String {
            let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
            return (text.addingPercentEncoding(withAllowedCharacters: allowed) ?? "").replacingOccurrences(of: "%20", with: "+")
        }
        return "spotify:local:\(escape(artist)):\(escape(album)):\(escape(title)):\(Int(duration))"
    }
    static func context(tracks: [[String: Any]], title: String, index: Int) -> [String: Any]? {
        guard tracks.indices.contains(index), !tracks.isEmpty,
              tracks.allSatisfy({ ($0["uri"] as? String)?.hasPrefix("spotify:local:") == true }) else { return nil }
        return ["operation":"play", "context":["uri":"spotify:local-files", "pages":[["tracks":tracks]],
                "metadata":["context_description":title]],
                "options":["skip_to":["track_index":index], "always_play_something":false, "initially_paused":false]]
    }
}
