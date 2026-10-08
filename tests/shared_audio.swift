import Foundation

@main struct SharedAudioTests {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let source = root.appendingPathComponent("source.m4a"), target = root.appendingPathComponent("target.m4a")
        let bytes = Data(repeating: 17, count: 4096)
        try bytes.write(to: source)
        func sameInode(_ a: URL, _ b: URL) throws -> Bool {
            let x = try fm.attributesOfItem(atPath: a.path), y = try fm.attributesOfItem(atPath: b.path)
            return x[.systemFileNumber] as? NSNumber == y[.systemFileNumber] as? NSNumber
        }
        guard try PWSharedAudioFile.materialize(source, at: target), try sameInode(source, target) else { fatalError("local files must share storage") }
        do { try PWSharedAudioFile.materialize(source, at: target); fatalError("existing target overwritten") } catch {}
        try fm.removeItem(at: target)
        guard try Data(contentsOf: source) == bytes else { fatalError("deleting a link removed the audio") }
        try fm.copyItem(at: source, to: target)
        guard PWSharedAudioFile.consolidate(source, target: target), try sameInode(source, target) else { fatalError("old identical copies not consolidated") }
        try Data(repeating: 23, count: 4096).write(to: target, options: .atomic)
        guard try Data(contentsOf: source) == bytes else { fatalError("atomic metadata replacement changed source") }
        guard !PWSharedAudioFile.consolidate(source, target: target) else { fatalError("different tags overwritten") }
        let symbolic = root.appendingPathComponent("symbolic.m4a")
        try fm.createSymbolicLink(at: symbolic, withDestinationURL: source)
        guard !PWSharedAudioFile.consolidate(source, target: symbolic) else { fatalError("symlink accepted") }
        do { try PWSharedAudioFile.materialize(symbolic, at: root.appendingPathComponent("bad.m4a")); fatalError("symlink source accepted") } catch {}
        print("Shared audio storage checks passed")
    }
}
