import Foundation

// Field names and enum cases verified in the 9.1.78 Swift metadata.
enum PWLibraryFilterRules {
    struct Section { var uris: [Int: String]; var controls: Bool }
    static func field(_ value: Any, _ name: String) -> Any? {
        var mirror: Mirror? = Mirror(reflecting: value)
        while let current = mirror {
            if let value = current.children.first(where: { $0.label == name })?.value { return value }
            mirror = current.superclassMirror
        }
        return nil
    }
    static func key(_ uri: String) -> String? {
        if uri == "spotify:collection:tracks" { return uri }
        let parts = uri.split(separator: ":")
        guard parts.first == "spotify", parts.count >= 3,
              parts[parts.count - 2] == "playlist" else { return nil }
        return "spotify:playlist:" + String(parts.last!)
    }
    static func sections(_ binder: Any) -> [Section]? {
        guard let model = field(binder, "model"), let content = field(model, "content"),
              let sections = field(content, "sections") as? [Any], sections.count <= 100 else { return nil }
        return sections.map { section in
            var uris: [Int: String] = [:]
            if let window = field(section, "items"), let items = field(window, "items") as? [Any],
               items.count <= 10000, let range = field(window, "range") as? Range<Int>, range.lowerBound >= 0 {
                for (offset, item) in items.enumerated() {
                    let entity = field(item, "contentItem") ?? field(item, "alsoAvailableOfflineItem")
                    if let info = entity.flatMap({ field($0, "entityInfo") }), let value = field(info, "uri"),
                       let uri = (value as? URL)?.absoluteString ?? value as? String, let key = key(uri) {
                        uris[range.lowerBound + offset] = key
                    }
                }
            }
            let header = field(section, "header").flatMap { field($0, "type") }
            return Section(uris: uris, controls: header.map { String(describing: $0) == "contentControls" } ?? false)
        }
    }
}
