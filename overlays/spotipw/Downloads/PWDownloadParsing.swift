import Foundation

// Foundation-only rules, also exercised on macOS in CI.
struct PWAudioTrack: Codable, Equatable {
    var id: String
    var title: String
    var artist: String
    var duration: Double
    var album: String?
    var artworkURL: String?
    var isrc: String?
    var year: String?
    func enriched(with newer: PWAudioTrack) -> PWAudioTrack {
        var result = newer
        result.album = newer.album ?? album; result.artworkURL = newer.artworkURL ?? artworkURL
        result.isrc = newer.isrc ?? isrc; result.year = newer.year ?? year
        return result
    }
}

struct PWAudioCandidate {
    var id: String
    var title: String
    var artist: String
    var duration: Double
}

struct PWSearchAttempt {
    let query: String
    let mode: String
    let params: String?
    static func plan(_ track: PWAudioTrack, music: Bool) -> [PWSearchAttempt] {
        let query = track.title + " " + track.artist
        // ytmusicapi get_search_params(..., ignore_spelling=True): preserve
        // the requested title instead of silently accepting search corrections.
        if music {
            return [PWSearchAttempt(query: query, mode: "songs_exact", params: "EgWKAQIIAUICCAFqDBAOEAoQAxAEEAkQBQ%3D%3D"),
                    PWSearchAttempt(query: query, mode: "videos_exact", params: "EgWKAQIQAUICCAFqDBAOEAoQAxAEEAkQBQ%3D%3D"),
                    PWSearchAttempt(query: query, mode: "all_exact", params: "EhGKAQ4IARABGAEgASgAOAFAAUICCAE%3D")]
        }
        return [PWSearchAttempt(query: query, mode: "videos", params: nil),
                PWSearchAttempt(query: track.artist + " \"" + track.title + "\"", mode: "quoted_title", params: nil)]
    }
}

// Stage names are fixed labels; diagnostic details are sanitized separately.
enum PWDownloadStage: String {
    case spotifyItems = "spotify_playlist_items", spotifyTracks = "spotify_playlist_tracks"
    case spotifyDocument = "spotify_playlist_document", spotifySaved = "spotify_saved_tracks"
    case youtubeMusicConfig = "youtube_music_config", youtubeConfig = "youtube_config"
    case youtubeMusicSearch = "youtube_music_search", youtubeSearch = "youtube_search"
    var spotify: Bool { rawValue.hasPrefix("spotify_") }
}
struct PWDownloadHTTPError: LocalizedError {
    let stage: PWDownloadStage
    let status: Int
    var errorDescription: String? {
        if stage.spotify {
            switch status {
            case 401: return "La session Spotify a expiré. Relance une chanson puis réessaie."
            case 403: return "Spotify refuse l’accès aux morceaux de cette playlist (HTTP 403). La recherche YouTube n’a pas démarré."
            case 404: return "Spotify ne trouve pas cette playlist ou n’en expose pas les morceaux (HTTP 404). La recherche YouTube n’a pas démarré."
            default: return "Chargement de la playlist Spotify : HTTP \(status)."
            }
        }
        let service = stage.rawValue.hasPrefix("youtube_music") ? "YouTube Music" : "YouTube"
        if status == 429 { return "\(service) limite les demandes (HTTP 429). La file est en pause ; réessaie plus tard." }
        return "\(service) : requête refusée ou indisponible (HTTP \(status), étape \(stage.rawValue)). Exporte les logs pour le diagnostic."
    }
}
struct PWYouTubeSearchConfig {
    let context: [String: Any]
    let version: String
    let clientNumber: String
    static func parse(_ html: String, music: Bool) -> PWYouTubeSearchConfig? {
        var config: [String: Any] = [:]
        // ytcfg.set can contain nested objects and braces inside quoted strings.
        // Decode the JSON without evaluating scripts from the remote page.
        for part in html.components(separatedBy: "ytcfg.set(").dropFirst() {
            let chars = Array(part.prefix(512000))
            var depth = 0, quoted = false, escaped = false, start: Int?
            for (i, char) in chars.enumerated() {
                if start == nil { if char == "{" { start = i; depth = 1 }; continue }
                if quoted {
                    if escaped { escaped = false }
                    else if char == "\\" { escaped = true }
                    else if char == "\"" { quoted = false }
                    continue
                }
                if char == "\"" { quoted = true }
                else if char == "{" { depth += 1 }
                else if char == "}" { depth -= 1 }
                if depth == 0, let begin = start {
                    if let data = String(chars[begin...i]).data(using: .utf8),
                       let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        config.merge(object) { _, new in new }
                    }
                    break
                }
            }
        }
        guard let context = config["INNERTUBE_CONTEXT"] as? [String: Any],
              let client = context["client"] as? [String: Any],
              client["clientName"] as? String == (music ? "WEB_REMIX" : "WEB"),
              let version = client["clientVersion"] as? String, !version.isEmpty, version.count < 80,
              version.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "_" || $0 == "-" }) else { return nil }
        // Keep only the public client description, not unrelated page state.
        return PWYouTubeSearchConfig(context: ["client": client], version: version, clientNumber: music ? "67" : "1")
    }
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
        text.replacingOccurrences(of: "’", with: "").replacingOccurrences(of: "'", with: "").folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }
    static func phrase(_ needle: [String], in haystack: [String]) -> Bool {
        guard !needle.isEmpty, needle.count <= haystack.count else { return false }
        return (0...(haystack.count - needle.count)).contains { Array(haystack[$0..<($0 + needle.count)]) == needle }
    }
    static func titleWords(_ text: String) -> [String] {
        // Featured credits often differ between Spotify and YouTube. Keep all
        // recording/version terms (live/remix/etc.), remove only bracketed credits.
        let clean = text.replacingOccurrences(of: #"(?i)[\(\[]\s*(?:feat\.?|ft\.?|featuring)\s+[^\)\]]+[\)\]]"#,
                                               with: "", options: .regularExpression)
        return words(clean)
    }
    static func rejection(_ candidate: PWAudioCandidate, for track: PWAudioTrack, requireYouTubeID: Bool = true) -> String? {
        guard !requireYouTubeID || identifier(candidate.id, length: 11) else { return "identifier" }
        guard track.duration.isFinite, candidate.duration.isFinite, track.duration > 0, candidate.duration > 0 else { return "missing_duration" }
        guard abs(candidate.duration - track.duration) <= max(8, track.duration * 0.05) else { return "duration" }
        let title = titleWords(track.title), found = titleWords(candidate.title)
        guard phrase(title, in: found) else { return "title" }
        guard phrase(words(track.artist), in: words(candidate.artist + " " + candidate.title)) else { return "artist" }
        for variant in ["live", "cover", "remix", "karaoke", "instrumental", "sped", "slowed", "nightcore", "acoustic"] {
            if found.contains(variant) != title.contains(variant) { return "version" }
        }
        return nil
    }
    static func score(_ candidate: PWAudioCandidate, for track: PWAudioTrack) -> Int? {
        guard rejection(candidate, for: track) == nil else { return nil }
        return (titleWords(track.title) == titleWords(candidate.title) ? 100 : 70) - Int(abs(candidate.duration - track.duration))
    }
    static func seconds(_ text: String) -> Double {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":")
        guard (2...3).contains(parts.count), parts.allSatisfy({ Int($0) != nil && Int($0)! >= 0 }), parts.dropFirst().allSatisfy({ Int($0)! < 60 }) else { return 0 }
        return parts.reduce(0) { $0 * 60 + (Double($1) ?? 0) }
    }
    static func text(_ object: Any?) -> String {
        guard let object = object as? [String: Any] else { return "" }
        if let simple = object["simpleText"] as? String { return simple }
        return (object["runs"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined()
    }
    static func nested(_ object: Any?, _ path: [String]) -> Any? {
        path.reduce(object) { value, key in (value as? [String: Any])?[key] }
    }
    static func durationText(_ value: String) -> Double {
        let pattern = #"(?<![0-9])(?:[0-9]{1,2}:)?[0-9]{1,3}:[0-5][0-9](?![0-9])"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.matches(in: value, range: NSRange(value.startIndex..., in: value)).last,
              let range = Range(match.range, in: value) else { return 0 }
        return seconds(String(value[range]))
    }
    static func rendererCounts(_ json: Any) -> String {
        var counts: [String: Int] = [:], visited = 0
        func walk(_ node: Any, _ depth: Int) {
            guard depth < 40, visited < 10000 else { return }; visited += 1
            if let array = node as? [Any] { for value in array { walk(value, depth + 1) } }
            if let dict = node as? [String: Any] {
                for (key, value) in dict {
                    if key.hasSuffix("Renderer") { counts[key, default: 0] += 1 }
                    walk(value, depth + 1)
                }
            }
        }
        walk(json, 0)
        return counts.keys.sorted().prefix(20).map { "\($0)=\(counts[$0]!)" }.joined(separator: ", ")
    }
    static func candidates(_ json: Any, music: Bool) -> [PWAudioCandidate] {
        var result: [PWAudioCandidate] = []
        func walk(_ node: Any, depth: Int) {
            guard depth < 40, result.count < 100 else { return }
            if let array = node as? [Any] { for item in array { walk(item, depth: depth + 1) }; return }
            guard let dict = node as? [String: Any] else { return }
            if music, let item = dict["musicResponsiveListItemRenderer"] as? [String: Any] {
                let columns = item["flexColumns"] as? [[String: Any]] ?? []
                let fields = columns.map { text(nested($0, ["musicResponsiveListItemFlexColumnRenderer", "text"])) }
                // Search rows use the overlay's play endpoint; playlistItemData
                // is only one of the possible shapes, not a required search field.
                let endpointID = nested(item, ["overlay", "musicItemThumbnailOverlayRenderer", "content", "musicPlayButtonRenderer", "playNavigationEndpoint", "watchEndpoint", "videoId"])
                let id = nested(item, ["playlistItemData", "videoId"]) as? String ?? endpointID as? String ?? nested(item, ["navigationEndpoint", "watchEndpoint", "videoId"]) as? String
                if let id = id, let title = fields.first, !title.isEmpty {
                    let fixed = item["fixedColumns"] as? [[String: Any]] ?? []
                    let fixedDuration = fixed.map { durationText(text(nested($0, ["musicResponsiveListItemFixedColumnRenderer", "text"]))) }.first { $0 > 0 } ?? 0
                    let details = fields.dropFirst().joined(separator: " • ")
                    result.append(PWAudioCandidate(id: id, title: title, artist: details,
                        duration: fixedDuration > 0 ? fixedDuration : durationText(details)))
                }
                return
            }
            if music, let item = dict["musicCardShelfRenderer"] as? [String: Any],
               let id = nested(item, ["onTap", "watchEndpoint", "videoId"]) as? String {
                let details = text(item["subtitle"])
                result.append(PWAudioCandidate(id: id, title: text(item["title"]), artist: details, duration: durationText(details)))
                // Also inspect the shelf's extra rows.
            }
            if !music, let item = dict["videoRenderer"] as? [String: Any], let id = item["videoId"] as? String {
                result.append(PWAudioCandidate(id: id, title: text(item["title"]), artist: text(item["ownerText"] ?? item["longBylineText"] ?? item["shortBylineText"]), duration: durationText(text(item["lengthText"]))))
                return
            }
            for key in dict.keys.sorted() { walk(dict[key]!, depth: depth + 1) }
        }
        walk(json, depth: 0)
        var resultByID: [String: PWAudioCandidate] = [:], order: [String] = []
        for item in result {
            if resultByID[item.id] == nil { order.append(item.id) }
            if resultByID[item.id] == nil || (resultByID[item.id]!.duration == 0 && item.duration > 0) { resultByID[item.id] = item }
        }
        return order.compactMap { resultByID[$0] }
    }
    static func tracks(_ items: [[String: Any]]) -> [PWAudioTrack] {
        items.compactMap { item in
            guard let t = (item["item"] ?? item["track"]) as? [String: Any],
                  t["type"] as? String == "track", t["is_local"] as? Bool != true,
                  let id = t["id"] as? String, identifier(id, length: 22),
                  let title = t["name"] as? String, !title.isEmpty,
                  let artist = (t["artists"] as? [[String: Any]])?.first?["name"] as? String,
                  !artist.isEmpty, let ms = t["duration_ms"] as? Double, ms > 0 else { return nil }
            let album = t["album"] as? [String: Any]
            return PWAudioTrack(id: id, title: title, artist: artist, duration: ms / 1000,
                album: album?["name"] as? String,
                artworkURL: (album?["images"] as? [[String: Any]])?.first?["url"] as? String,
                isrc: (t["external_ids"] as? [String: Any])?["isrc"] as? String,
                year: (album?["release_date"] as? String).map { String($0.prefix(4)) })
        }
    }
    static func filename(_ track: PWAudioTrack) -> String {
        let clean = (track.artist + " - " + track.title).components(separatedBy: CharacterSet(charactersIn: "/\\:\n\r\0").union(.controlCharacters)).joined(separator: " ")
        return String(clean.prefix(100)).trimmingCharacters(in: .whitespacesAndNewlines) + ".m4a"
    }
    static func mediaURL(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        return url.scheme == "https" && url.user == nil && url.password == nil && (host == "googlevideo.com" || host.hasSuffix(".googlevideo.com"))
    }
}

// Detailed diagnostics contain useful metadata, never raw headers/response bodies.
enum PWDownloadLog {
    static func clean(_ text: String) -> String {
        var value = text
        for pattern in [#"(?i)(?:https?|file)://[^\s\"<>]+"#,
                        #"(?i)(?:Bearer|OAuth)\s+[^\s,;\"]+"#,
                        #"(?i)(?:access_token|refresh_token|authorization|cookie|SOCS|CONSENT)["']?\s*[:=]\s*["']?[^\s,;"'}]+"#] {
            value = value.replacingOccurrences(of: pattern, with: "[redacted]", options: .regularExpression)
        }
        return String(value.prefix(800))
    }
    static func fields(_ details: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [:]
        for (key, value) in details.prefix(40) {
            guard !["authorization", "cookie", "set-cookie", "access_token", "refresh_token", "url", "headers", "body"].contains(key.lowercased()) else { continue }
            if let text = value as? String { result[key] = clean(text) }
            else if let number = value as? NSNumber, number.doubleValue.isFinite { result[key] = number }
        }
        return result
    }
    static func error(_ error: Error) -> [String: Any] {
        let ns = error as NSError
        var fields: [String: Any] = ["error_type": String(reflecting: type(of: error)), "error_domain": ns.domain,
                                   "error_code": ns.code, "error_message": ns.localizedDescription]
        if let cause = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            fields["underlying_domain"] = cause.domain; fields["underlying_code"] = cause.code
            fields["underlying_message"] = cause.localizedDescription
        }
        return Self.fields(fields)
    }
}
