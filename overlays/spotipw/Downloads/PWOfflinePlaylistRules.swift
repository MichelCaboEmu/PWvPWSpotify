import Foundation

// Playlist membership and file availability are different facts. Never build a
// queue by enumerating all downloaded files, and never replace an unavailable
// selected row with a different song.
enum PWOfflinePlaylistRules {
    struct Plan: Equatable {
        var ids: [String]
        var index: Int
    }
    static func plan(members: [String], available: Set<String>, selected: String?) -> Plan? {
        let ids = members.filter { available.contains($0) }
        guard !ids.isEmpty else { return nil }
        if let selected = selected {
            guard let index = ids.firstIndex(of: selected) else { return nil }
            return Plan(ids: ids, index: index)
        }
        return Plan(ids: ids, index: 0)
    }
    static func members(live: [String], complete: Bool, saved: [String]) -> [String] {
        // A complete current snapshot takes precedence (including removals and
        // order). A partial snapshot must not discard cached unloaded neighbours.
        if complete || saved.isEmpty { return live }
        let known = Set(saved)
        return saved + live.filter { !known.contains($0) }
    }
}
