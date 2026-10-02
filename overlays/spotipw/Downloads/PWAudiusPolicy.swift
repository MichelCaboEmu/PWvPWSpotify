import Foundation

enum PWAudiusPolicy {
    // Audius is decentralized. Accept only exact node origins announced by its
    // track/user metadata, in addition to Audius' own domain; never arbitrary redirects.
    static func announcedHosts(_ row: [String: Any]) -> Set<String> {
        let values = [row["placement_hosts"] as? String,
            (row["user"] as? [String: Any])?["creator_node_endpoint"] as? String].compactMap { $0 }
        var hosts = Set<String>()
        for text in values.flatMap({ $0.split(separator: ",").map(String.init) }) {
            guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), validOrigin(url), let host = url.host?.lowercased() else { continue }
            hosts.insert(host)
        }
        return hosts
    }
    static func validOrigin(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil, url.port == nil || url.port == 443,
              let host = url.host?.lowercased(), host.contains("."),
              !host.contains(":"), host.contains(where: { $0.isLetter }),
              !["localhost", "local", "internal", "home", "lan", "test", "invalid"].contains(host.split(separator: ".").last.map(String.init) ?? "") else { return false }
        return !host.hasSuffix(".localhost") && host != "localhost"
    }
    static func mediaURL(_ url: URL, announced: Set<String> = []) -> Bool {
        guard validOrigin(url), let host = url.host?.lowercased() else { return false }
        return host == "audius.co" || host.hasSuffix(".audius.co") || announced.contains(host)
    }
}
