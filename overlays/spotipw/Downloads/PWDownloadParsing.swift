import Foundation

// Foundation-only rules, also exercised on macOS in CI.
struct PWAudioTrack: Codable, Equatable {
    var id: String
    var title: String
    var artist: String
    var duration: Double
}

struct PWAudioCandidate {
    var id: String
    var title: String
    var artist: String
    var duration: Double
}

enum PWDownloadRules {
    static func identifier(_ text: String, length: Int) -> Bool {
        text.count == length && text.unicodeScalars.allSatisfy {
            (48...57).contains($0.value) || (65...90).contains($0.value) || (97...122).contains($0.value)
                || (length == 11 && ($0 == "_" || $0 == "-"))
        }
    }

    static func playlistPath(_ uri: String) -> String? {
        if uri == "spotify:collection:tracks" || uri.hasPrefix("spotify:user:") && uri.hasSuffix(":collection") {
            return "/v1/me/tracks"
        }
        let parts = uri.components(separatedBy: ":")
        if let i = parts.firstIndex(of: "playlist"), i + 2 == parts.count,
           parts.first == "spotify", identifier(parts[i + 1], length: 22) {
            return "/v1/playlists/\(parts[i + 1])/items"
        }
        if let url = URL(string: uri), url.scheme == "https", url.host == "open.spotify.com",
           url.pathComponents.count == 3, url.pathComponents[1] == "playlist",
           identifier(url.lastPathComponent, length: 22) {
            return "/v1/playlists/\(url.lastPathComponent)/items"
        }
        return nil
    }

    static func words(_ text: String) -> [String] {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }
    static func phrase(_ needle: [String], in haystack: [String]) -> Bool {
        guard !needle.isEmpty, needle.count <= haystack.count else { return false }
        return (0...(haystack.count - needle.count)).contains { Array(haystack[$0..<($0 + needle.count)]) == needle }
    }
    static func score(_ candidate: PWAudioCandidate, for track: PWAudioTrack) -> Int? {
        guard identifier(candidate.id, length: 11), track.duration > 0, candidate.duration > 0,
              abs(candidate.duration - track.duration) <= max(8, track.duration * 0.05) else { return nil }
        let title = words(track.title), found = words(candidate.title)
        guard phrase(title, in: found), phrase(words(track.artist), in: words(candidate.artist + " " + candidate.title)) else { return nil }
        // Do not silently replace the requested recording with a cover/remix/live edit.
        for variant in ["live", "cover", "remix", "karaoke", "instrumental", "sped", "slowed", "nightcore", "acoustic"] {
            if found.contains(variant) != title.contains(variant) { return nil }
        }
        return (title == found ? 100 : 70) - Int(abs(candidate.duration - track.duration))
    }
    static func seconds(_ text: String) -> Double {
        let parts = text.split(separator: ":")
        guard (2...3).contains(parts.count), parts.allSatisfy({ Int($0) != nil }) else { return 0 }
        return parts.reduce(0) { $0 * 60 + (Double($1) ?? 0) }
    }
    static func text(_ object: Any?) -> String {
        guard let object = object as? [String: Any] else { return "" }
        if let simple = object["simpleText"] as? String { return simple }
        return (object["runs"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined()
    }
    static func candidates(_ json: Any, music: Bool) -> [PWAudioCandidate] {
        var result: [PWAudioCandidate] = []
        func walk(_ node: Any, depth: Int) {
            guard depth < 40, result.count < 100 else { return }
            if let array = node as? [Any] { for item in array { walk(item, depth: depth + 1) }; return }
            guard let dict = node as? [String: Any] else { return }
            if music, let item = dict["musicResponsiveListItemRenderer"] as? [String: Any],
               let data = item["playlistItemData"] as? [String: Any], let id = data["videoId"] as? String {
                let columns = item["flexColumns"] as? [[String: Any]] ?? []
                func column(_ i: Int) -> String {
                    guard i < columns.count, let col = columns[i]["musicResponsiveListItemFlexColumnRenderer"] as? [String: Any] else { return "" }
                    return text(col["text"])
                }
                let fixed = item["fixedColumns"] as? [[String: Any]] ?? []
                let time = fixed.first?["musicResponsiveListItemFixedColumnRenderer"] as? [String: Any]
                let details = column(1)
                let duration = seconds(text(time?["text"]))
                let alternative = details.components(separatedBy: " • ").compactMap { seconds($0) > 0 ? seconds($0) : nil }.last ?? 0
                result.append(PWAudioCandidate(id: id, title: column(0), artist: details, duration: duration > 0 ? duration : alternative))
                return
            }
            if !music, let item = dict["videoRenderer"] as? [String: Any], let id = item["videoId"] as? String {
                result.append(PWAudioCandidate(id: id, title: text(item["title"]), artist: text(item["ownerText"] ?? item["longBylineText"]), duration: seconds(text(item["lengthText"]))))
                return
            }
            for value in dict.values { walk(value, depth: depth + 1) }
        }
        walk(json, depth: 0)
        var seen = Set<String>()
        return result.filter { seen.insert($0.id).inserted }
    }
    static func tracks(_ items: [[String: Any]]) -> [PWAudioTrack] {
        items.compactMap { item in
            guard let t = (item["item"] ?? item["track"]) as? [String: Any],
                  t["type"] as? String == "track", t["is_local"] as? Bool != true,
                  let id = t["id"] as? String, identifier(id, length: 22),
                  let title = t["name"] as? String, !title.isEmpty,
                  let artist = (t["artists"] as? [[String: Any]])?.first?["name"] as? String,
                  !artist.isEmpty, let ms = t["duration_ms"] as? Double, ms > 0 else { return nil }
            return PWAudioTrack(id: id, title: title, artist: artist, duration: ms / 1000)
        }
    }
    static func filename(_ track: PWAudioTrack) -> String {
        let clean = (track.artist + " - " + track.title).components(separatedBy: CharacterSet(charactersIn: "/\\:\n\r\0").union(.controlCharacters)).joined(separator: " ")
        return String(clean.prefix(100)) + " [" + track.id + "].m4a"
    }
    static func mediaURL(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        return url.scheme == "https" && url.user == nil && url.password == nil && (host == "googlevideo.com" || host.hasSuffix(".googlevideo.com"))
    }
}
