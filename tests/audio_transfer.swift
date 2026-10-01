import Foundation

private final class Observations: @unchecked Sendable {
    let lock = NSLock()
    var events: [String] = []
    var progress = false
    func event(_ name: String) { lock.lock(); events.append(name); lock.unlock() }
    func advance() { lock.lock(); progress = true; lock.unlock() }
    func hasProgress() -> Bool { lock.lock(); defer { lock.unlock() }; return progress }
    func contains(_ name: String) -> Bool { lock.lock(); defer { lock.unlock() }; return events.contains(name) }
}
@main enum AudioTransferTests {
    static func main() async throws {
        let base = CommandLine.arguments[1]
        var count = 0
        func check(_ value: Bool, _ message: String) {
            count += 1; if !value { fatalError("FAIL: " + message) }
        }
        check(PWAudioTransfer.completeRange("bytes 0-4095/4096") == 4096, "whole range")
        for range in ["bytes 1-4095/4096", "bytes 0-200/4096", "bytes 0-4095/*", "bytes 0-0/0", "bytes 0-999999999/1000000000"] {
            check(PWAudioTransfer.completeRange(range) == nil, "reject partial or excessive range")
        }
        for route in ["ok206", "ok200", "denied", "partial", "truncated", "large", "stall", "cancel"] {
            let observed = Observations()
            let transfer = PWAudioTransfer(timeout: route == "stall" ? 0.5 : 3,
                allowed: { $0.scheme == "http" && $0.host == "127.0.0.1" },
                report: { event, _, _ in observed.event(event) }, progress: { _, _ in observed.advance() })
            let url = URL(string: base + "/" + route)!
            let started = Date()
            let work = Task { try await transfer.download(url) }
            if route == "cancel" { try await Task.sleep(nanoseconds: 100_000_000); work.cancel() }
            do {
                let file = try await work.value
                defer { try? FileManager.default.removeItem(at: file) }
                check(route.hasPrefix("ok"), "only valid full responses succeed: " + route)
                let data = try Data(contentsOf: file)
                check(data == Data(repeating: 65, count: 4096), "exact completed bytes")
                check(observed.hasProgress(), "progress callback runs during transfer")
                check(observed.contains("audio_http") && observed.contains("audio_transfer_finished"), "headers and completion reported")
            } catch {
                check(!route.hasPrefix("ok"), "valid response must not fail: " + route + ": " + error.localizedDescription)
                if route == "stall" {
                    check((error as? URLError)?.code == .timedOut, "stall terminates with real timeout")
                    check(Date().timeIntervalSince(started) < 5, "stall bounded")
                }
                if route == "cancel" {
                    check(error is CancellationError || (error as? URLError)?.code == .cancelled, "cancellation is not an audio failure")
                }
                check(observed.contains("audio_transfer_failed"), "failed transfer reported")
            }
        }
        let observed = Observations()
        let refused = URL(string: base + "/denied")!
        let good = URL(string: base + "/ok206")!
        let alternative = try await PWAudioTransfer.downloadAlternatives([refused, refused, good],
            allowed: { $0.scheme == "http" && $0.host == "127.0.0.1" },
            report: { event, _, _ in observed.event(event) }, progress: { _, _ in })
        defer { try? FileManager.default.removeItem(at: alternative) }
        check(observed.contains("audio_stream_alternative"), "refused stream advances to an already returned alternative")
        check(try Data(contentsOf: alternative).count == 4096, "alternative produces complete audio bytes")
        let limited = URL(string: base + "/limited")!
        do {
            let unexpected = try await PWAudioTransfer.downloadAlternatives([limited, good],
                allowed: { $0.host == "127.0.0.1" }, report: { _, _, _ in }, progress: { _, _ in })
            try? FileManager.default.removeItem(at: unexpected)
            fatalError("FAIL: HTTP 429 must stop rather than try another stream")
        } catch let error as PWAudioHTTPError { check(error.status == 429, "rate limit stops fallback") }
        print("PASS: \(count) audio transfer checks")
    }
}
