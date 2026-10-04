import Foundation
import UIKit
import AVFoundation

// Readable by Spotify's metadata getters on any thread. Only imported files in
// our manifest are exposed, never arbitrary paths received from track metadata.
enum PWNativeArtwork {
    private static let lock = NSLock()
    private static let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    private static var files: [String: String] = {
        let manifest = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PWDownloads/native-import.json")
        guard let size = try? manifest.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 16 * 1024 * 1024,
              let data = try? Data(contentsOf: manifest), let records = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else { return [:] }
        var result: [String: String] = [:]
        for record in records.values {
            if let uri = record["uri"] as? String, uri.hasPrefix("spotify:local:"),
               let name = record["filename"] as? String, PWLibraryCatalog.safeComponent(name) { result[uri] = name }
        }
        return result
    }()
    static func register(uri: String, filename: String) {
        guard uri.hasPrefix("spotify:local:"), PWLibraryCatalog.safeComponent(filename) else { return }
        lock.lock(); files[uri] = filename; lock.unlock()
    }
    static func file(for uri: String) -> URL? {
        guard uri.hasPrefix("spotify:local:") else { return nil }
        lock.lock(); let name = files[uri]; lock.unlock()
        guard let name = name else { return nil }
        let file = directory.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }
}

extension PWDownloadsBridge {
    @objc(nativeArtworkURLForURI:)
    nonisolated static func nativeArtworkURL(for uri: String) -> URL? {
        PWNativeArtwork.file(for: uri).flatMap(PWNativeLocalIdentity.artworkURL)
    }
    @objc(loadNativeArtworkForURI:completion:)
    static func loadNativeArtwork(for uri: String, completion: @escaping (UIImage?) -> Void) {
        guard let file = PWNativeArtwork.file(for: uri) else { completion(nil); return }
        Task {
            do {
                let asset = AVURLAsset(url: file)
                let tags = try await asset.load(.commonMetadata)
                guard let art = tags.first(where: { $0.commonKey == .commonKeyArtwork }),
                      let data = try await art.load(.dataValue), data.count <= 24 * 1024 * 1024,
                      let image = UIImage(data: data) else {
                    pwEvent("native_artwork_missing"); completion(nil); return
                }
                pwEvent("native_artwork_loaded", details: ["width":image.size.width, "height":image.size.height])
                completion(image)
            } catch { pwEvent("native_artwork_failed", details: PWDownloadLog.error(error)); completion(nil) }
        }
    }
}
