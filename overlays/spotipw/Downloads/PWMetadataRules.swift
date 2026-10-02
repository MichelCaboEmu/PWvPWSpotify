import Foundation

enum PWMetadataRules {
    static func artworkURL(_ text: String) -> String? {
        if text.hasPrefix("spotify:image:") {
            let id = String(text.dropFirst(14))
            guard id.count == 40, id.allSatisfy({ $0.isHexDigit }) else { return nil }
            return "https://i.scdn.co/image/" + id
        }
        guard let url = URL(string: text), url.scheme == "https", url.host == "i.scdn.co", url.user == nil, url.password == nil else { return nil }
        return text
    }
    static func bestArtwork(_ covers: [String: String]) -> String? {
        func rank(_ key: String) -> Int {
            let digits = key.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }.max() ?? 0
            if digits > 0 { return digits }
            let key = key.lowercased()
            if key.contains("xlarge") || key.contains("extra") { return 1000 }
            if key.contains("large") { return 640 }
            if key.contains("medium") { return 300 }
            if key.contains("small") { return 64 }
            return 0
        }
        return covers.sorted { rank($0.key) == rank($1.key) ? $0.key < $1.key : rank($0.key) > rank($1.key) }
            .compactMap { artworkURL($0.value) }.first
    }
    static func albumMatches(_ candidate: String?, _ expected: String?) -> Bool {
        guard let expected = expected, !expected.isEmpty else { return true }
        guard let candidate = candidate else { return false }
        return PWDownloadRules.words(candidate) == PWDownloadRules.words(expected)
    }
    static func appleMatch(_ rows: [[String: Any]], track: PWAudioTrack) -> [String: Any]? {
        let matches = rows.filter { row in
            let title = row["trackName"] as? String ?? ""
            let candidate = PWAudioCandidate(id: "", title: title, artist: row["artistName"] as? String ?? "", duration: (row["trackTimeMillis"] as? Double ?? 0) / 1000)
            return PWDownloadRules.rejection(candidate, for: track, requireYouTubeID: false) == nil &&
                PWDownloadRules.titleWords(title) == PWDownloadRules.titleWords(track.title) &&
                albumMatches(row["collectionName"] as? String, track.album)
        }
        // Without the original album, don't choose a cover from competing releases.
        if track.album == nil && Set(matches.compactMap { ($0["collectionName"] as? String).map(PWDownloadRules.words) }).count > 1 { return nil }
        return matches.min { abs(($0["trackTimeMillis"] as? Double ?? 0) / 1000 - track.duration) < abs(($1["trackTimeMillis"] as? Double ?? 0) / 1000 - track.duration) }
    }
}
