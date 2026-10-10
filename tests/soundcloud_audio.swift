import Foundation
import AVFoundation
import AudioToolbox

// The app's error/UI diagnostics boundary is intentionally replaced, while the
// actual public adapter, transfer and native audio converter compile unchanged.
struct PWDownloadError: LocalizedError {
    let message: String; var pausesQueue = false; var fallbackEligible = false
    var errorDescription: String? { message }
}
func pwError(_ message: String) -> PWDownloadError { PWDownloadError(message: message) }
func pwEvent(_ event: String, _ code: Int = 0, details: [String: Any] = [:]) {}

@main enum SoundCloudAudioTests {
    static func main() async throws {
        let encoded = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
        let fixture = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // Simulate the transfer's .m4a path with a public MP3 stream split into
        // fragments, then concatenate exactly as the HLS adapter does.
        let input = root.appendingPathComponent("transfer.m4a")
        let midpoint = fixture.count / 2
        var joined = Data(fixture.prefix(midpoint)); joined.append(fixture.suffix(from: midpoint))
        try joined.write(to: input)
        let output = try await PWSoundCloudAudio.convert(input, duration: 12)
        defer { try? FileManager.default.removeItem(at: output) }
        let asset = AVURLAsset(url: output)
        let duration = try await asset.load(.duration).seconds
        guard abs(duration - 12) < 0.5 else { fatalError("SoundCloud M4A duration wrong") }
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let reader = try AVAssetReader(asset: asset)
        let decoded = AVAssetReaderTrackOutput(track: tracks[0], outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
        reader.add(decoded); guard reader.startReading() else { throw reader.error! }
        var samples = 0
        while let buffer = decoded.copyNextSampleBuffer() { samples += CMSampleBufferGetNumSamples(buffer) }
        guard reader.status == .completed, samples > 44000 * 11 else { fatalError("Incomplete SoundCloud decoded audio") }
        let preview = root.appendingPathComponent("preview.mp3"); try fixture.write(to: preview)
        do {
            let unexpected = try await PWSoundCloudAudio.convert(preview, duration: 60)
            try? FileManager.default.removeItem(at: unexpected); fatalError("Preview accepted as full track")
        } catch { }
        let corrupt = root.appendingPathComponent("corrupt.mp3"); try Data("not audio".utf8).write(to: corrupt)
        do {
            let unexpected = try await PWSoundCloudAudio.convert(corrupt, duration: 12)
            try? FileManager.default.removeItem(at: unexpected); fatalError("Corrupt audio accepted")
        } catch { }
        print("PASS: native SoundCloud MP3 → M4A conversion, full decode and incomplete-file rejection")
    }
}
