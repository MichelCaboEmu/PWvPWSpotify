import Foundation

struct PWAudioHTTPError: LocalizedError {
    let status: Int
    var errorDescription: String? {
        "Flux audio refusé (HTTP \(status)). Aucun fichier enregistré."
    }
}

// Own a single transfer. Delegate callbacks run on one serial queue; cancellation
// may arrive on another executor and only touches the locked task reference.
final class PWAudioTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let maximumBytes: Int64 = 128 * 1024 * 1024
    private let lock = NSLock()
    private var task: URLSessionDataTask?
    private var continuation: CheckedContinuation<URL, Error>?
    private var cancelled = false
    private var session: URLSession?
    private var handle: FileHandle?
    private var failure: Error?
    private var received: Int64 = 0
    private var expected: Int64 = -1
    private var lastProgress: TimeInterval = 0
    private let started = ProcessInfo.processInfo.systemUptime
    private let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
    private let allowed: @Sendable (URL) -> Bool
    private let report: @Sendable (String, Int, [String: Any]) -> Void
    private let progress: @Sendable (Int64, Int64) -> Void
    private let timeout: TimeInterval

    init(timeout: TimeInterval = 120,
         allowed: @escaping @Sendable (URL) -> Bool = { PWDownloadRules.mediaURL($0) },
         report: @escaping @Sendable (String, Int, [String: Any]) -> Void,
         progress: @escaping @Sendable (Int64, Int64) -> Void) {
        self.timeout = timeout; self.allowed = allowed; self.report = report; self.progress = progress
    }
    // Only try alternate URLs already returned for this same video. No new
    // identity, account, proxy or repeated retry of a refused URL is introduced.
    static func downloadAlternatives(_ urls: [URL], timeout: TimeInterval = 120,
         allowed: @escaping @Sendable (URL) -> Bool = { PWDownloadRules.mediaURL($0) },
         report: @escaping @Sendable (String, Int, [String: Any]) -> Void,
         progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> URL {
        var seen = Set<URL>()
        let candidates = Array(urls.filter { allowed($0) && seen.insert($0).inserted }.prefix(3))
        guard !candidates.isEmpty else { throw URLError(.unsupportedURL) }
        for (index, url) in candidates.enumerated() {
            try Task.checkCancellation()
            report("audio_stream_attempt", index + 1, ["available_streams": candidates.count])
            let transfer = PWAudioTransfer(timeout: timeout, allowed: allowed, report: { event, code, details in
                report(event, code, details.merging(["stream_attempt": index + 1]) { _, new in new })
            }, progress: progress)
            do { return try await transfer.download(url) }
            catch let error as PWAudioHTTPError where [403, 410].contains(error.status) && index + 1 < candidates.count {
                report("audio_stream_alternative", error.status, ["next_attempt": index + 2])
            }
        }
        throw URLError(.resourceUnavailable)
    }
    private func error(_ message: String) -> NSError {
        NSError(domain: "PWAudioTransfer", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    // A 206 response is complete only when its range covers the entire resource.
    static func completeRange(_ value: String?) -> Int64? {
        guard let value = value, value.hasPrefix("bytes 0-") else { return nil }
        let parts = value.dropFirst(8).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let end = Int64(parts[0]), let total = Int64(parts[1]),
              total > 0, total <= maximumBytes, end == total - 1 else { return nil }
        return total
    }
    func download(_ url: URL) async throws -> URL {
        guard allowed(url) else { throw error("Adresse du flux audio non autorisée.") }
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if cancelled { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                self.continuation = continuation
                let config = URLSessionConfiguration.ephemeral
                config.httpCookieStorage = nil; config.urlCredentialStorage = nil
                config.urlCache = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
                config.timeoutIntervalForRequest = min(20, timeout)
                config.timeoutIntervalForResource = timeout
                let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
                let session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
                self.session = session
                var request = URLRequest(url: url)
                request.timeoutInterval = min(20, timeout)
                request.httpShouldHandleCookies = false
                // Request the full byte range explicitly (audio servers may pace
                // ordinary playback requests). Do not change signed URL values.
                request.setValue("bytes=0-", forHTTPHeaderField: "Range")
                request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                request.setValue(PWYouTubeAccess.userAgent, forHTTPHeaderField: "User-Agent")
                let task = session.dataTask(with: request); self.task = task
                lock.unlock(); task.resume()
            }
        }, onCancel: {
            self.lock.lock(); self.cancelled = true; let task = self.task; self.lock.unlock()
            task?.cancel()
        })
    }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, allowed(url) else { completionHandler(nil); return }
        var redirected = request
        redirected.setValue(nil, forHTTPHeaderField: "Authorization")
        redirected.setValue(nil, forHTTPHeaderField: "Cookie")
        redirected.setValue("bytes=0-", forHTTPHeaderField: "Range")
        redirected.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        completionHandler(redirected)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, let url = http.url, allowed(url) else {
            failure = error("Réponse audio invalide."); completionHandler(.cancel); return
        }
        expected = response.expectedContentLength
        report("audio_http", http.statusCode, ["expected_bytes": expected, "content_type": http.mimeType ?? "unknown",
            "elapsed_ms": Int((ProcessInfo.processInfo.systemUptime - started) * 1000),
            "content_range": http.value(forHTTPHeaderField: "Content-Range") ?? ""])
        guard http.statusCode == 200 || http.statusCode == 206 else {
            failure = PWAudioHTTPError(status: http.statusCode)
            completionHandler(.cancel); return
        }
        if http.statusCode == 206 {
            guard let total = Self.completeRange(http.value(forHTTPHeaderField: "Content-Range")),
                  expected < 0 || expected == total else {
                failure = error("Le serveur audio a renvoyé une plage incomplète. Aucun fichier enregistré.")
                completionHandler(.cancel); return
            }
            expected = total
        }
        guard expected <= Self.maximumBytes else {
            failure = error("Fichier audio trop volumineux (limite 128 Mo).")
            completionHandler(.cancel); return
        }
        do {
            guard FileManager.default.createFile(atPath: file.path, contents: nil) else { throw error("Impossible de créer le fichier audio temporaire.") }
            handle = try FileHandle(forWritingTo: file)
            progress(0, expected); completionHandler(.allow)
        } catch { failure = error; completionHandler(.cancel) }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil else { return }
        guard received + Int64(data.count) <= Self.maximumBytes else {
            failure = error("Le flux audio dépasse 128 Mo. Transfert arrêté."); dataTask.cancel(); return
        }
        do { try handle?.write(contentsOf: data) }
        catch { failure = error; dataTask.cancel(); return }
        received += Int64(data.count)
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        if elapsed - lastProgress >= 2 || received == expected {
            lastProgress = elapsed
            report("audio_progress", 0, ["bytes": received, "expected_bytes": expected,
                "elapsed_ms": Int(elapsed * 1000), "bytes_per_second": Int(Double(received) / max(0.001, elapsed))])
            progress(received, expected)
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError networkError: Error?) {
        do { try handle?.close() } catch { if failure == nil { failure = error } }
        handle = nil
        var terminal = failure ?? networkError
        if terminal == nil, received <= 1024 || (expected >= 0 && received != expected) {
            terminal = error("Fichier audio incomplet : \(received) octets reçus, \(expected) attendus.")
        }
        if let terminal = terminal {
            report("audio_transfer_failed", (terminal as NSError).code,
                PWDownloadLog.error(terminal).merging(["bytes": received, "expected_bytes": expected,
                    "elapsed_ms": Int((ProcessInfo.processInfo.systemUptime - started) * 1000)]) { _, new in new })
            try? FileManager.default.removeItem(at: file)
        } else { report("audio_transfer_finished", 0, ["bytes": received]) }
        lock.lock(); let continuation = self.continuation; self.continuation = nil; self.task = nil; lock.unlock()
        self.session = nil; session.finishTasksAndInvalidate()
        if let terminal = terminal { continuation?.resume(throwing: terminal) }
        else { continuation?.resume(returning: file) }
    }
}
