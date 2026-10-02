import Foundation

struct PWDownloadDestination: Codable, Equatable {
    let uri: String
    let title: String
    init?(uri: String?, title: String?) {
        guard let uri = uri, PWDownloadRules.playlistPath(uri) != nil,
              let title = title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        self.uri = uri; self.title = title
    }
}

struct PWStoredFile { var directory: String; var filename: String }
struct PWPlaylistFolder: Codable {
    var name: String
    var tracks: [String: String] = [:]
}
struct PWPlaylistFolderIndex: Codable {
    var playlists: [String: PWPlaylistFolder] = [:]
    static func name(_ title: String) -> String {
        let cleaned = title.components(separatedBy: CharacterSet(charactersIn: "/\\:").union(.controlCharacters)).joined(separator: " ")
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return cleaned.isEmpty ? "Titres téléchargés" : String(cleaned.prefix(100))
    }
    mutating func reserve(uri: String, title: String, occupied: Set<String>) -> String {
        if let old = playlists[uri], PWLibraryCatalog.safeComponent(old.name) { return old.name }
        let base = Self.name(title)
        let taken = Set((Array(occupied) + playlists.values.map(\.name)).map { $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")) })
        var result = base, suffix = 2
        while taken.contains(result.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))) {
            result = base + " (\(suffix))"; suffix += 1
        }
        playlists[uri] = PWPlaylistFolder(name: result); return result
    }
}
