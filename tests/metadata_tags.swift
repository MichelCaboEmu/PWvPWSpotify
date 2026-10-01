import Foundation
import AVFoundation
import AudioToolbox

@main enum MetadataTests {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.m4a")
        let encoded = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
        try Data(base64Encoded: encoded, options: .ignoreUnknownCharacters)!.write(to: source)
        let normalized = try await PWAudioContainer.normalize(source, expectedDuration: 12)
        defer { try? FileManager.default.removeItem(at: normalized) }
        let track = PWAudioTrack(id: "1234567890123456789012", title: "91’s — épreuve", artist: "Artiste", duration: 12)
        let basic = try await PWAudioTags.tag(normalized, track: track, match: nil)
        defer { try? FileManager.default.removeItem(at: basic) }
        let asset = AVURLAsset(url: basic)
        let firstTags = try await asset.load(.commonMetadata)
        precondition(firstTags.first(where: { $0.commonKey == .commonKeyTitle })?.stringValue == track.title, "basic title embedded")
        precondition(firstTags.first(where: { $0.commonKey == .commonKeyArtist })?.stringValue == track.artist)
        let artwork = Data(base64Encoded: "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/2wBDAQkJCQwLDBgNDRgyIRwhMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjL/wAARCAACAAIDASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwDSooorxj80P//Z")!
        let enriched = try await PWAudioTags.tag(basic, track: track,
            match: PWMetadataMatch(title: "Titre corrigé", artist: "Artiste", album: "Album", year: "2026", artwork: artwork))
        defer { try? FileManager.default.removeItem(at: enriched) }
        let output = AVURLAsset(url: enriched)
        let tags = try await output.load(.commonMetadata)
        precondition(tags.first(where: { $0.commonKey == .commonKeyTitle })?.stringValue == "Titre corrigé", "existing title replaced")
        precondition(tags.first(where: { $0.commonKey == .commonKeyAlbumName })?.stringValue == "Album")
        precondition(tags.first(where: { $0.commonKey == .commonKeyArtwork })?.dataValue == artwork, "cover embedded")
        let all = try await output.load(.metadata)
        precondition(all.contains(where: { $0.stringValue == "2026" }), "year embedded")
        let reader = try AVAssetReader(asset: output)
        let audio = try await output.loadTracks(withMediaType: .audio)
        let decoded = AVAssetReaderTrackOutput(track: audio[0], outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsNonInterleaved: false])
        reader.add(decoded); precondition(reader.startReading())
        var seconds = 0.0
        while let buffer = decoded.copyNextSampleBuffer() {
            guard CMSampleBufferGetNumSamples(buffer) > 0 else { continue }
            let format = CMAudioFormatDescriptionGetStreamBasicDescription(CMSampleBufferGetFormatDescription(buffer)!)!.pointee
            seconds += Double(CMSampleBufferGetNumSamples(buffer)) / format.mSampleRate
        }
        precondition(reader.status == .completed && abs(seconds - 12) < 0.1, "metadata update preserves fully decodable audio")
        precondition(FileManager.default.fileExists(atPath: basic.path), "source survives")
        print("Metadata tags: basic tags, replacement, album, year and PCM decode passed")
    }
}
