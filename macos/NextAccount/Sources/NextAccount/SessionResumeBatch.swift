import Foundation

/// Serial dispatch avoids competing Desktop navigation or queue processes.
/// Callers should open each thread (deep-link) before queueing so Desktop
/// actually picks up the continue turn. Failed threads do not prevent the
/// remaining conversations from resuming.
@MainActor
enum SessionResumeBatch {
    struct Result {
        let total: Int
        let succeeded: Int
    }

    static func run(
        threadIDs: [String],
        shouldContinue: () -> Bool,
        progress: (Int, Int) -> Void,
        enqueue: (String) async -> Bool
    ) async -> Result {
        var seen = Set<String>()
        let ids = threadIDs.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && seen.insert($0).inserted }
        var succeeded = 0
        for (index, id) in ids.enumerated() {
            guard !Task.isCancelled, shouldContinue() else { break }
            progress(index + 1, ids.count)
            if await enqueue(id) { succeeded += 1 }
        }
        return Result(total: ids.count, succeeded: succeeded)
    }
}
