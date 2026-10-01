import Foundation
import AVFoundation

struct PWMetadataMatch {
    var title: String
    var artist: String
    var album: String?
    var year: String?
    var artwork: Data?
    var source: String = "Apple iTunes"
}
enum PWAudioTags {
    private static func tagError(_ message: String) -> NSError {
        NSError(domain: "PWAudioTags", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    static func tag(_ file: URL, track: PWAudioTrack, match: PWMetadataMatch?) async throws -> URL {
        let asset = AVURLAsset(url: file, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough),
              export.supportedFileTypes.contains(.m4a) else { throw tagError("Ce fichier ne permet pas la mise à jour des métadonnées sans conversion.") }
        let target = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        var success = false
        defer { if !success { try? FileManager.default.removeItem(at: target) } }
        var tags: [AVMetadataItem] = []
        func text(_ id: AVMetadataIdentifier, _ value: String?) {
            guard let value = value, !value.isEmpty else { return }
            let item = AVMutableMetadataItem(); item.identifier = id; item.value = value as NSString; item.extendedLanguageTag = "und"; tags.append(item)
        }
        text(.commonIdentifierTitle, match?.title ?? track.title)
        text(.commonIdentifierArtist, match?.artist ?? track.artist)
        text(.commonIdentifierAlbumName, match?.album ?? track.album)
        text(.iTunesMetadataReleaseDate, match?.year ?? track.year)
        if let artwork = match?.artwork {
            let item = AVMutableMetadataItem(); item.identifier = .commonIdentifierArtwork; item.value = artwork as NSData; item.dataType = "com.apple.metadata.datatype.JPEG"; tags.append(item)
        }
        let replacing = Set(tags.compactMap(\.identifier))
        let replacingKeys = Set(tags.compactMap { $0.commonKey?.rawValue })
        let existing = try await asset.load(.metadata)
        export.metadata = existing.filter { item in
            if let key = item.commonKey?.rawValue, replacingKeys.contains(key) { return false }
            return item.identifier.map { !replacing.contains($0) } ?? true
        } + tags
        export.outputURL = target; export.outputFileType = .m4a
        let timeout = Task { try await Task.sleep(nanoseconds: 60_000_000_000); export.cancelExport() }
        defer { timeout.cancel() }
        try await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in export.exportAsynchronously { continuation.resume() } }
            try Task.checkCancellation()
            guard export.status == .completed else { throw export.error ?? tagError("Mise à jour interrompue ou trop longue ; le fichier original est conservé.") }
        }, onCancel: { export.cancelExport() })
        let output = AVURLAsset(url: target, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let duration = try await output.load(.duration).seconds
        let original = try await asset.load(.duration).seconds
        guard duration.isFinite, abs(duration - original) < 0.25, !((try await output.loadTracks(withMediaType: .audio)).isEmpty) else {
            throw tagError("La vérification audio après mise à jour a échoué ; l’original est conservé.")
        }
        success = true; return target
    }
}
