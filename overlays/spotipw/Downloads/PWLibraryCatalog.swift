import Foundation

struct PWLocalEntry: Codable {
    var track: PWAudioTrack
    var folder: Data?
    var directory: String
    var filename: String
    var album: String?
    var year: String?
    var metadataSource: String?
    var metadataError: String?
    var playlistURI: String?
}
struct PWLocalPlaylist: Codable {
    var uri: String
    var title: String
    var trackIDs: [String]
    var files: [String: PWLocalEntry]?
}
struct PWLibraryCatalog: Codable {
    var version = 1
    var entries: [String: PWLocalEntry] = [:]
    var playlists: [String: PWLocalPlaylist] = [:]

    mutating func remember(uri: String, title: String, tracks: [PWAudioTrack], complete: Bool) {
        var ids = tracks.map(\.id)
        if !complete { ids += playlists[uri]?.trackIDs ?? [] }
        var seen = Set<String>()
        let old = playlists[uri]?.files
        playlists[uri] = PWLocalPlaylist(uri: uri, title: title, trackIDs: ids.filter { seen.insert($0).inserted }, files: old)
    }
    static func safeComponent(_ text: String) -> Bool {
        !text.isEmpty && text != "." && text != ".." && !text.contains("/") && !text.contains("\\")
    }
}
