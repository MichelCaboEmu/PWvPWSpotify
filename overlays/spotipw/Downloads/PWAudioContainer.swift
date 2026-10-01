import Foundation
import AVFoundation
import CoreMedia
import AudioToolbox

// YouTube's fragmented DASH M4A is a transport container, not a finished local
// audio file. Copy AAC packets into a fresh M4A and validate that result. Never
// divide an estimated duration by two or remove a duration check to accept it.
enum PWAudioContainer {
    private static func error(_ message: String) -> NSError {
        NSError(domain: "PWAudioContainer", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    static func normalize(_ source: URL, expectedDuration: Double,
                          report: @Sendable (String, [String: Any]) -> Void = { _, _ in }) async throws -> URL {
        try Task.checkCancellation()
        guard expectedDuration.isFinite, expectedDuration > 0 else { throw error("Durée attendue invalide.") }
        let asset = AVURLAsset(url: source, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let declaredDuration = try await asset.load(.duration).seconds
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        report("audio_container_input", ["declared_duration": declaredDuration, "expected_duration": expectedDuration,
                                        "audio_tracks": tracks.count])
        guard tracks.count == 1 else { throw error("Le fichier ne contient pas une piste audio unique exploitable.") }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: tracks[0], outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw error("Le format audio ne peut pas être lu sur cet appareil.") }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? error("Lecture des paquets audio impossible.") }
        defer { if reader.status == .reading { reader.cancelReading() } }
        guard let first = output.copyNextSampleBuffer(), let format = CMSampleBufferGetFormatDescription(first),
              let audioFormat = CMAudioFormatDescriptionGetStreamBasicDescription(format),
              audioFormat.pointee.mFormatID == kAudioFormatMPEG4AAC else {
            throw reader.error ?? error("Le fichier ne contient pas de paquets AAC lisibles.")
        }
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        let writer = try AVAssetWriter(url: destination, fileType: .m4a)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: format)
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw error("Création du conteneur M4A impossible.") }
        writer.add(input)
        var succeeded = false
        defer {
            if !succeeded {
                writer.cancelWriting()
                try? FileManager.default.removeItem(at: destination)
            }
        }
        let firstTime = CMSampleBufferGetPresentationTimeStamp(first)
        guard firstTime.isNumeric, firstTime.seconds.isFinite else { throw error("Horodatage audio initial invalide.") }
        guard writer.startWriting() else { throw writer.error ?? error("Écriture du conteneur M4A impossible.") }
        // Starting at the first packet maps its timestamp to zero without
        // speeding up the audio or using the container's estimated duration.
        writer.startSession(atSourceTime: firstTime)
        let deadline = ProcessInfo.processInfo.systemUptime + 60
        var buffer: CMSampleBuffer? = first
        var end = firstTime
        var buffers = 0
        var packets = 0
        var packetDuration = 0.0
        while let sample = buffer {
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw error("Préparation du fichier audio trop longue (60 s).") }
            while !input.isReadyForMoreMediaData {
                try Task.checkCancellation()
                guard writer.status == .writing else { throw writer.error ?? error("Écriture audio interrompue.") }
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw error("Préparation du fichier audio trop longue (60 s).") }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            // AVAssetReader can emit a zero-sample end marker with invalid
            // PTS and zero duration. It carries no audio packet to remux.
            if CMSampleBufferGetNumSamples(sample) == 0 {
                guard CMSampleBufferGetTotalSampleSize(sample) == 0 else { throw error("Bloc audio sans échantillons mais contenant des données.") }
                report("audio_container_empty_marker", ["after_buffers": buffers])
                buffer = output.copyNextSampleBuffer()
                continue
            }
            let time = CMSampleBufferGetPresentationTimeStamp(sample)
            let duration = CMSampleBufferGetDuration(sample)
            guard time.isNumeric, duration.isNumeric, time.seconds.isFinite, duration.seconds.isFinite,
                  duration.seconds > 0, time.seconds >= end.seconds - 0.05,
                  time.seconds <= end.seconds + 0.1 else {
                report("audio_container_timing_error", ["buffer": buffers, "timestamp": time.seconds,
                    "buffer_duration": duration.seconds, "previous_end": end.seconds,
                    "samples": CMSampleBufferGetNumSamples(sample), "sample_rate": audioFormat.pointee.mSampleRate,
                    "frames_per_packet": audioFormat.pointee.mFramesPerPacket])
                throw error("Horodatage audio invalide au bloc \(buffers) : position \(time.seconds), durée \(duration.seconds), fin précédente \(end.seconds), échantillons \(CMSampleBufferGetNumSamples(sample)).")
            }
            guard input.append(sample) else { throw writer.error ?? error("Impossible de recopier les paquets audio.") }
            end = CMTimeAdd(time, duration)
            packetDuration += duration.seconds
            packets += CMSampleBufferGetNumSamples(sample); buffers += 1
            buffer = output.copyNextSampleBuffer()
        }
        try Task.checkCancellation()
        guard reader.status == .completed else { throw reader.error ?? error("La lecture des paquets audio est incomplète.") }
        let timelineDuration = CMTimeSubtract(end, firstTime).seconds
        report("audio_container_packets", ["buffers": buffers, "packets": packets,
            "packet_duration": packetDuration, "timeline_duration": timelineDuration,
            "sample_rate": audioFormat.pointee.mSampleRate])
        let tolerance = max(8, expectedDuration * 0.05)
        guard packetDuration.isFinite, abs(packetDuration - expectedDuration) <= tolerance,
              abs(timelineDuration - packetDuration) <= 0.25 else {
            throw error(String(format: "Durée audio différente : %.2f s de paquets reçus, %.2f s attendues. Aucun fichier enregistré.", packetDuration, expectedDuration))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: end)
        await withTaskCancellationHandler(operation: { await writer.finishWriting() }, onCancel: { writer.cancelWriting() })
        try Task.checkCancellation()
        guard writer.status == .completed else { throw writer.error ?? error("Finalisation du M4A impossible.") }
        let normalized = AVURLAsset(url: destination, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let actualDuration = try await normalized.load(.duration).seconds
        let audio = try await normalized.loadTracks(withMediaType: .audio)
        let bytes = try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        report("audio_validation", ["declared_duration": declaredDuration, "actual_duration": actualDuration,
            "packet_duration": packetDuration, "expected_duration": expectedDuration,
            "audio_tracks": audio.count, "bytes": bytes, "container_normalized": true])
        guard audio.count == 1, bytes > 1024, bytes <= 128 * 1024 * 1024,
              actualDuration.isFinite, abs(actualDuration - expectedDuration) <= tolerance,
              abs(actualDuration - packetDuration) <= 0.25 else {
            throw error(String(format: "Le M4A préparé reste incohérent : %.2f s, contre %.2f s attendues. Aucun fichier enregistré.", actualDuration, expectedDuration))
        }
        try Task.checkCancellation()
        succeeded = true
        return destination
    }
}
