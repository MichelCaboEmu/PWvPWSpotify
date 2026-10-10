import Foundation

// es_local_files.proto embedded in Spotify 9.1.78: Folder.path = 1;
// MutateSourceResponse.result = 1 (SUCCESS=1, NOT_CHANGED=3).
enum PWNativeFolderProtocol {
    static let documentsPayload = Data([8, 6, 16, 1]) // IOS_DOCUMENTS enabled
    static let tracksPayload = Data([10, 5, 26, 3, 16, 144, 78]) // query.range.length=10000
    static func payload(path: String) -> Data? {
        let bytes = Array(path.utf8)
        guard path.hasPrefix("/"), !bytes.contains(0), bytes.count < 16384 else { return nil }
        var result = Data([0x0a]), length = bytes.count
        repeat { result.append(UInt8(length & 0x7f) | (length > 127 ? 0x80 : 0)); length >>= 7 } while length > 0
        result.append(contentsOf: bytes); return result
    }
    static func accepted(response: Data) -> Bool {
        guard let fields = fields(response) else { return false }
        let results = fields.filter { $0.tag == 1 }
        return results.count == 1 && results[0].wire == 0 && [1, 3].contains(results[0].number)
    }
    struct Field { let tag: Int; let wire: Int; let number: UInt64; let bytes: Data }
    static func fields(_ data: Data) -> [Field]? {
        guard data.count <= 16 * 1024 * 1024 else { return nil }
        let bytes = Array(data); var position = 0; var result: [Field] = []
        func number() -> UInt64? {
            var value: UInt64 = 0
            for shift in stride(from: 0, to: 70, by: 7) {
                guard position < bytes.count else { return nil }
                let byte = bytes[position]; position += 1
                guard shift < 63 || byte <= 1 else { return nil }
                value |= UInt64(byte & 127) << shift
                if byte < 128 { return value }
            }
            return nil
        }
        while position < bytes.count {
            guard result.count < 100000, let key = number(), key >> 3 > 0, key >> 3 <= 536870911 else { return nil }
            let wire = Int(key & 7); var value: UInt64 = 0; var payload = Data()
            if wire == 0 { guard let n = number() else { return nil }; value = n }
            else if wire == 2 {
                guard let length = number(), length <= UInt64(bytes.count - position) else { return nil }
                payload = Data(bytes[position..<position + Int(length)]); position += Int(length)
            } else if wire == 1 || wire == 5 {
                let length = wire == 1 ? 8 : 4
                guard position + length <= bytes.count else { return nil }; position += length
            } else { return nil }
            result.append(Field(tag: Int(key >> 3), wire: wire, number: value, bytes: payload))
        }
        return result
    }
    static func indexedURIs(response: Data) -> Set<String>? {
        guard let outer = fields(response),
              let status = outer.first(where: { $0.tag == 1 && $0.wire == 2 }).flatMap({ fields($0.bytes) }),
              status.first(where: { $0.tag == 1 && $0.wire == 0 })?.number == 200,
              let body = outer.first(where: { $0.tag == 2 && $0.wire == 2 }).flatMap({ fields($0.bytes) }) else { return nil }
        var uris = Set<String>()
        for item in body where item.tag == 1 && item.wire == 2 {
            guard let values = fields(item.bytes) else { return nil }
            if let value = values.first(where: { $0.tag == 5 && $0.wire == 2 }),
               let uri = String(data: value.bytes, encoding: .utf8), uri.hasPrefix("spotify:local:") { uris.insert(uri) }
        }
        return uris
    }
}
