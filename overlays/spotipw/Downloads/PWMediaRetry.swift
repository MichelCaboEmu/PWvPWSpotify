import Foundation

enum PWMediaRetry {
    // Exactly two logical attempts; refreshing extraction belongs to operation.
    // Only the final error is exposed to the fallback decision.
    static func run<T>(operation: (Int) async throws -> T, forbidden: (Error) -> Bool,
                       waiting: () -> Void, sleep: () async throws -> Void = { try await Task.sleep(nanoseconds: 3_000_000_000) }) async throws -> T {
        try Task.checkCancellation()
        do { return try await operation(1) }
        catch {
            try Task.checkCancellation()
            guard forbidden(error) else { throw error }
            waiting(); try await sleep(); try Task.checkCancellation()
            return try await operation(2)
        }
    }
}
