import Foundation
import AVFoundation

@main enum AudioContainerTests {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let encoded = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
        let fixture = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters)!
        var declared = fixture
        // Static DASH may declare the full duration in the initial headers as
        // well as carrying timestamps in fragments. Exercise both layouts.
        func uint32(_ data: Data, _ offset: Int) -> UInt32 {
            data[offset..<offset + 4].reduce(0) { ($0 << 8) | UInt32($1) }
        }
        func write(_ value: UInt32, _ offset: Int) {
            for i in 0..<4 { declared[offset + i] = UInt8(truncatingIfNeeded: value >> ((3 - i) * 8)) }
        }
        func patch(_ start: Int, _ end: Int) {
            var offset = start
            while offset + 8 <= end {
                let size = Int(uint32(declared, offset))
                guard size >= 8, offset + size <= end else { return }
                let tag = String(data: declared[offset + 4..<offset + 8], encoding: .ascii)!
                if tag == "mvhd" || tag == "mdhd" { write(uint32(declared, offset + 20) * 12, offset + 24) }
                if tag == "tkhd" { write(12000, offset + 28) }
                if ["moov", "trak", "mdia"].contains(tag) { patch(offset + 8, offset + size) }
                offset += size
            }
        }
        patch(0, declared.count)
        var checks = 0
        func check(_ value: Bool, _ message: String) { checks += 1; if !value { fatalError("FAIL: " + message) } }
        for (name, data) in [("fragmented", fixture), ("declared-fragmented", declared)] {
            let source = root.appendingPathComponent(name + ".m4a")
            try data.write(to: source)
            let result = try await PWAudioContainer.normalize(source, expectedDuration: 12) { event, fields in
                print(event, fields)
            }
            defer { try? FileManager.default.removeItem(at: result) }
            let asset = AVURLAsset(url: result, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            let duration = try await asset.load(.duration).seconds
            check(abs(duration - 12) < 0.1, "normalized duration matches actual audio")
            // Decode the output too: a plausible duration header alone is not
            // enough to demonstrate that a saved M4A is actually playable.
            let decoded = try AVAudioFile(forReading: result)
            let buffer = AVAudioPCMBuffer(pcmFormat: decoded.processingFormat, frameCapacity: 4096)!
            var frames: Int64 = 0
            while true {
                try decoded.read(into: buffer)
                if buffer.frameLength == 0 { break }
                frames += Int64(buffer.frameLength)
            }
            check(abs(Double(frames) / decoded.processingFormat.sampleRate - 12) < 0.1, "M4A decodes to twelve seconds, not twenty-four")
            do {
                let wrong = try await PWAudioContainer.normalize(source, expectedDuration: 24)
                try? FileManager.default.removeItem(at: wrong)
                fatalError("FAIL: a real duration mismatch must not be accepted by dividing by two")
            } catch { check(true, "wrong song duration still rejected") }
        }
        let corrupt = root.appendingPathComponent("corrupt.m4a")
        try Data(repeating: 0, count: 4096).write(to: corrupt)
        do {
            let file = try await PWAudioContainer.normalize(corrupt, expectedDuration: 12)
            try? FileManager.default.removeItem(at: file)
            fatalError("FAIL: corrupt media accepted")
        } catch { check(true, "corrupt media rejected") }
        print("PASS: \(checks) audio container checks")
    }
}
