import Foundation

// es_local_files.proto embedded in Spotify 9.1.78: Folder.path = 1;
// MutateSourceResponse.result = 1 (SUCCESS=1, NOT_CHANGED=3).
enum PWNativeFolderProtocol {
    static func payload(path: String) -> Data? {
        let bytes = Array(path.utf8)
        guard path.hasPrefix("/"), !bytes.contains(0), bytes.count < 16384 else { return nil }
        var result = Data([0x0a]), length = bytes.count
        repeat { result.append(UInt8(length & 0x7f) | (length > 127 ? 0x80 : 0)); length >>= 7 } while length > 0
        result.append(contentsOf: bytes); return result
    }
    static func accepted(response: Data) -> Bool {
        // Unknown/empty/malformed replies must never authorize cleanup.
        response == Data([0x08, 0x01]) || response == Data([0x08, 0x03])
    }
}
