// Optional live probe: Blender's public Big Buck Bunny sample, HEAD only, no media retained.
import Foundation

extension Bundle {
    static var pwYouTubeKit: Bundle { Bundle(url: URL(fileURLWithPath: CommandLine.arguments[1]))! }
}
@main enum ExtractorSmoke {
    static func main() async {
        do { try await probe() }
        catch {
            print("EXTRACTOR_PROBE_FAILED: \(String(describing: error))")
            exit(1)
        }
    }
    static func probe() async throws {
        let video = YouTube(videoID: "aqz-KE-bpKQ", methods: [.local])
        // Public test video only. Report the provider's rejection, not a generic extractError.
        let client = InnerTube(client: .visionOS, signatureTimestamp: try await video.signatureTimestamp,
                               ytcfg: try await video.ytcfg, useOAuth: false, allowCache: false)
        let info = try await client.player(videoID: "aqz-KE-bpKQ")
        print("Provider status: \(info.playabilityStatus?.status ?? "missing"); reason: \(info.playabilityStatus?.reason ?? "none"); streaming data: \(info.streamingData != nil)")
        let streams = try await video.streams
        guard let audio = streams.filterAudioOnly().filter({ $0.fileExtension == .m4a }).highestAudioBitrateStream(),
              PWDownloadRules.mediaURL(audio.url) else { throw NSError(domain: "NoLocalAudio", code: 1) }
        var request = URLRequest(url: audio.url, timeoutInterval: 15)
        request.httpMethod = "HEAD"
        let (_, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        print("Local extractor probe: HTTP \(status); no audio downloaded")
        guard status == 200 || status == 206 else { throw NSError(domain: "AudioHTTP", code: status) }
    }
}
