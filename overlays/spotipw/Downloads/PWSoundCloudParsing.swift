import Foundation

struct PWSoundCloudHTTPError: LocalizedError {
    let stage: String
    let status: Int
    var errorDescription: String? { "SoundCloud : étape \(stage) refusée (HTTP \(status))." }
}

struct PWSoundCloudMatch {
    let candidate: PWAudioCandidate
    let transcodings: [(url: URL, protocolName: String)]
    let evidence: String
}
enum PWSoundCloudRules {
    static func https(_ url: URL) -> Bool {
        url.scheme == "https" && url.user == nil && url.password == nil && (url.port == nil || url.port == 443)
    }
    static func apiURL(_ url: URL) -> Bool { https(url) && url.host?.lowercased() == "api-v2.soundcloud.com" }
    static func mediaURL(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        return https(url) && host.hasSuffix(".sndcdn.com") && !previewURL(url)
    }
    static func webURL(_ url: URL) -> Bool {
        https(url) && (url.host == "soundcloud.com" || url.host == "www.soundcloud.com" || url.host == "a-v2.sndcdn.com")
    }
    static func previewURL(_ url: URL) -> Bool {
        let path = url.path.lowercased()
        return path.contains("/preview/") || path.contains("/playlist/0/30/")
    }
    static func matches(_ text: String, pattern: String, group: Int = 1) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            guard let range = Range($0.range(at: group), in: text) else { return nil }
            return String(text[range])
        }
    }
    static func clientID(_ script: String) -> String? {
        matches(script, pattern: #"\bclient_id\s*:\s*["']([A-Za-z0-9]{32})["']"#).first
    }
    static func scripts(_ html: String) -> [URL] {
        matches(html, pattern: #"(?i)<script\b[^>]*\bsrc\s*=\s*["']([^"']+)["']"#).reversed().compactMap {
            guard let url = URL(string: $0, relativeTo: URL(string: "https://soundcloud.com/")!)?.absoluteURL,
                  webURL(url), url.path.hasSuffix(".js") else { return nil }
            return url
        }
    }
    static func endpoint(_ url: URL, clientID: String) -> URL? {
        guard apiURL(url), PWDownloadRules.identifier(clientID, length: 32),
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        parts.queryItems = (parts.queryItems ?? []).filter { $0.name != "client_id" } + [URLQueryItem(name: "client_id", value: clientID)]
        return parts.url
    }
    static func match(_ row: [String: Any], track: PWAudioTrack) -> (PWSoundCloudMatch?, String) {
        let user = row["user"] as? [String: Any] ?? [:]
        let publisher = row["publisher_metadata"] as? [String: Any] ?? [:]
        let artist = publisher["artist"] as? String ?? user["username"] as? String ?? ""
        let candidate = PWAudioCandidate(id: (row["id"] as? NSNumber)?.stringValue ?? "", title: row["title"] as? String ?? "",
            artist: artist, duration: (row["duration"] as? NSNumber)?.doubleValue ?? 0)
        var audio = candidate; audio.duration /= 1000
        guard !audio.id.isEmpty, row["streamable"] as? Bool == true,
              row["sharing"] as? String == "public" else { return (nil, "not_public_full_audio") }
        // MONETIZE is also used by public, complete artist recordings. It is
        // not a preview/subscription flag. Still require an unsnipped compatible
        // stream and validate the actual downloaded duration before saving.
        guard ["ALLOW", "MONETIZE"].contains(row["policy"] as? String ?? "") else { return (nil, "access_policy") }
        if let reason = PWRecordingPolicy.recordingRejection(audio, for: track) { return (nil, reason) }
        guard PWRecordingPolicy.artistMatches(artist, track.artist) else { return (nil, "artist_identity") }
        let expectedISRC = track.isrc?.uppercased().filter { $0.isLetter || $0.isNumber } ?? ""
        let actualISRC = (publisher["isrc"] as? String)?.uppercased().filter { $0.isLetter || $0.isNumber } ?? ""
        if !expectedISRC.isEmpty, !actualISRC.isEmpty, expectedISRC != actualISRC { return (nil, "isrc") }
        let verified = user["verified"] as? Bool == true && PWRecordingPolicy.artistMatches(user["username"] as? String ?? "", track.artist)
        let matchingISRC = expectedISRC.count == 12 && expectedISRC == actualISRC
        guard verified || matchingISRC else { return (nil, "provenance_unconfirmed") }
        let rows = (row["media"] as? [String: Any])?["transcodings"] as? [[String: Any]] ?? []
        let streams = rows.compactMap { transcoding -> (url: URL, protocolName: String)? in
            let format = transcoding["format"] as? [String: Any] ?? [:]
            guard let protocolName = format["protocol"] as? String, ["progressive", "hls"].contains(protocolName),
                  (format["mime_type"] as? String)?.hasPrefix("audio/mpeg") == true,
                  transcoding["snipped"] as? Bool != true, transcoding["quality"] as? String != "hq",
                  let text = transcoding["url"] as? String, let url = URL(string: text), apiURL(url), !previewURL(url),
                  !url.path.contains("encrypted") else { return nil }
            return (url, protocolName)
        }.sorted { $0.protocolName == "progressive" && $1.protocolName != "progressive" }
        guard !streams.isEmpty else { return (nil, "no_public_mp3") }
        return (PWSoundCloudMatch(candidate: audio, transcodings: streams, evidence: matchingISRC ? "isrc" : "verified_artist"), "accepted")
    }
    static func noMatchMessage(candidates: Int, rejections: [String: Int]) -> String {
        guard candidates > 0 else { return "SoundCloud : la recherche n’a renvoyé aucun titre. Aucun fichier enregistré." }
        let labels = ["not_public_full_audio": "titre privé ou lecture indisponible", "access_policy": "accès bloqué ou limité à un extrait",
                      "duration": "durée différente", "title": "titre différent", "title_extra": "titre ambigu", "version": "autre version",
                      "artist": "artiste différent", "artist_identity": "identité de l’artiste différente", "isrc": "identifiant d’enregistrement différent",
                      "provenance_unconfirmed": "provenance non confirmée", "no_public_mp3": "aucun flux MP3 complet compatible"]
        let reasons = rejections.keys.sorted().map { "\(labels[$0] ?? "autre incompatibilité") : \(rejections[$0]!)" }.joined(separator: ", ")
        return "SoundCloud : aucune correspondance compatible parmi \(candidates) titres. Motifs : \(reasons). Aucun fichier enregistré."
    }
    // Only finite, unencrypted MP3 media playlists. No keys, DRM, partial byte
    // ranges or remote files outside SoundCloud's media CDN are accepted.
    static func segments(_ text: String, base: URL, expectedDuration: Double) -> [URL]? {
        guard text.utf8.count < 1024 * 1024, text.hasPrefix("#EXTM3U"), text.contains("#EXT-X-ENDLIST"),
              expectedDuration.isFinite, expectedDuration > 0 else { return nil }
        var urls: [URL] = [], duration = 0.0, nextDuration: Double?
        for line in text.components(separatedBy: .newlines).map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if line.hasPrefix("#EXTINF:") {
                guard nextDuration == nil, let seconds = Double(line.dropFirst(8).split(separator: ",", omittingEmptySubsequences: false)[0]),
                      seconds.isFinite, seconds > 0, seconds <= 60 else { return nil }
                nextDuration = seconds
            } else if line.hasPrefix("#EXT-X-KEY:") {
                guard line == "#EXT-X-KEY:METHOD=NONE" else { return nil }
            } else if ["#EXT-X-MAP", "#EXT-X-BYTERANGE", "#EXT-X-STREAM-INF", "#EXT-X-DISCONTINUITY", "#EXT-X-GAP"].contains(where: { line.hasPrefix($0) }) {
                return nil
            } else if !line.isEmpty, !line.hasPrefix("#") {
                guard let seconds = nextDuration, urls.count < 600,
                      let url = URL(string: line, relativeTo: base)?.absoluteURL, mediaURL(url) else { return nil }
                urls.append(url); duration += seconds; nextDuration = nil
            }
        }
        guard !urls.isEmpty, nextDuration == nil, abs(duration - expectedDuration) <= max(8, expectedDuration * 0.05) else { return nil }
        return urls
    }
}
