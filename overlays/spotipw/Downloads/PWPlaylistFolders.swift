import Foundation

extension PWDownloadFiles {
    // This index belongs to the destination, not to a queue job. Clearing a queue
    // or downloading the same playlist again cannot create a new directory.
    func saveToPlaylist(_ temporary: URL, track: PWAudioTrack, job: PWDownloadJob) throws -> PWStoredFile {
        try Task.checkCancellation()
        let root = try Self.root(for: job), scoped = root.startAccessingSecurityScopedResource()
        defer { if scoped { root.stopAccessingSecurityScopedResource() } }
        var coordination: NSError?, operation: Error?, stored: PWStoredFile?
        NSFileCoordinator().coordinate(writingItemAt: root, options: .forMerging, error: &coordination) { root in
            do {
                let fm = FileManager.default
                try fm.createDirectory(at: root, withIntermediateDirectories: true)
                let indexURL = root.appendingPathComponent(".pw-playlist-folders.json")
                var index = PWPlaylistFolderIndex()
                if fm.fileExists(atPath: indexURL.path) {
                    let bytes = try Data(contentsOf: indexURL)
                    guard bytes.count < 8 * 1024 * 1024 else { throw pwError("Index des dossiers trop volumineux.") }
                    index = try JSONDecoder().decode(PWPlaylistFolderIndex.self, from: bytes)
                }
                let occupied = Set(try fm.contentsOfDirectory(atPath: root.path))
                let identity = job.destination?.uri ?? (job.uri.hasPrefix("spotify:track:") ? "pw:individual-tracks" : job.uri)
                let name = index.reserve(uri: identity, title: job.destination?.title ?? (job.uri.hasPrefix("spotify:track:") ? "Titres individuels" : job.title), occupied: occupied)
                let directory = root.appendingPathComponent(name, isDirectory: true)
                try fm.createDirectory(at: directory, withIntermediateDirectories: true)
                if let old = index.playlists[identity]?.tracks[track.id], PWLibraryCatalog.safeComponent(old),
                   ((try? directory.appendingPathComponent(old).resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) > 1024 {
                    stored = PWStoredFile(directory: name, filename: old); return
                }
                let preferred = PWDownloadRules.filename(track), base = String(PWDownloadRules.filename(track).dropLast(4))
                var filename = preferred, suffix = 2
                while fm.fileExists(atPath: directory.appendingPathComponent(filename).path) {
                    filename = base + " (\(suffix)).m4a"; suffix += 1
                }
                try Task.checkCancellation()
                let destination = directory.appendingPathComponent(filename)
                try PWSharedAudioFile.materialize(temporary, at: destination)
                index.playlists[identity]?.tracks[track.id] = filename
                do { try JSONEncoder().encode(index).write(to: indexURL, options: .atomic) }
                catch { try? fm.removeItem(at: destination); throw error }
                stored = PWStoredFile(directory: name, filename: filename)
            } catch { operation = error }
        }
        if let error = operation ?? coordination { throw error }
        guard let stored = stored else { throw pwError("Le dossier de la playlist n’a pas été enregistré.") }
        return stored
    }
    func copyToPlaylist(_ entry: PWLocalEntry, job: PWDownloadJob) throws -> PWStoredFile {
        let source = try entry.location(), scoped = source.root.startAccessingSecurityScopedResource()
        defer { if scoped { source.root.stopAccessingSecurityScopedResource() } }
        return try saveToPlaylist(source.file, track: entry.track, job: job)
    }
}
