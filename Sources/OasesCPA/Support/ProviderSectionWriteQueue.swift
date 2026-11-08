import Foundation

/// Runs this app's writes to one provider section of the engine configuration
/// (`openai-compatibility`, `gemini-api-key`, …) one after another.
///
/// The engine has no compare-and-set: several of these writes are a read of the whole list
/// followed by a PUT of the whole list (append, priority), and a provider edit is a PATCH and
/// then such a list write. Two of them running at the same time inside the app could each
/// write back a list read before the other's change. Serialising them per section closes that
/// window for this app (the same rule as the web panel's `enqueueProviderSectionWrite`);
/// another client writing in between is still last-writer-wins.
///
/// An operation starts after the previous one of its section has finished, whether that one
/// succeeded or failed; sections do not wait for each other.
@MainActor
final class ProviderSectionWriteQueue {
    private var tails: [String: Task<Void, Never>] = [:]

    /// The sections that currently have a write running or waiting (for tests).
    var pendingSections: [String] { tails.keys.sorted() }

    func run<T: Sendable>(
        section: String,
        _ operation: @escaping @MainActor @Sendable () async throws -> T
    ) async throws -> T {
        let previous = tails[section]
        let task = Task { @MainActor () async throws -> T in
            await previous?.value
            return try await operation()
        }
        let settled = Task { @MainActor () async -> Void in
            _ = await task.result
        }
        tails[section] = settled
        defer {
            if tails[section] == settled { tails[section] = nil }
        }
        return try await task.value
    }
}
