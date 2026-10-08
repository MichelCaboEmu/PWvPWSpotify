import Foundation

// Separate playlist paths may share one inode. Never edit audio in place:
// metadata writers must continue replacing files atomically.
enum PWSharedAudioFile {
    @discardableResult
    static func materialize(_ source: URL, at destination: URL) throws -> Bool {
        let fm = FileManager.default
        let attributes = try fm.attributesOfItem(atPath: source.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        do { try fm.linkItem(at: source, to: destination); return true }
        catch {
            // copyItem also refuses an existing destination. External providers
            // and volumes without hard links retain the working copy behavior.
            try fm.copyItem(at: source, to: destination); return false
        }
    }

    // Only call for a target owned by our manifest. Preserve different bytes
    // (e.g. an import with repaired tags) and retain the old file on link failure.
    @discardableResult
    static func consolidate(_ source: URL, target: URL) -> Bool {
        let fm = FileManager.default
        guard let a = try? fm.attributesOfItem(atPath: source.path),
              let b = try? fm.attributesOfItem(atPath: target.path),
              a[.type] as? FileAttributeType == .typeRegular,
              b[.type] as? FileAttributeType == .typeRegular else { return false }
        if let device = a[.systemNumber] as? NSNumber, let inode = a[.systemFileNumber] as? NSNumber,
           device == b[.systemNumber] as? NSNumber, inode == b[.systemFileNumber] as? NSNumber { return true }
        guard a[.size] as? NSNumber == b[.size] as? NSNumber,
              fm.contentsEqual(atPath: source.path, andPath: target.path) else { return false }
        let staging = target.deletingLastPathComponent().appendingPathComponent(".pw-share-" + UUID().uuidString)
        defer { try? fm.removeItem(at: staging) }
        do {
            try fm.linkItem(at: source, to: staging)
            _ = try fm.replaceItemAt(target, withItemAt: staging)
            return true
        } catch { return false }
    }
}
