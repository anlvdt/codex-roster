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

/// A navigation is confirmed only by a fresh success record for that exact thread.
enum DesktopResumeEvidence {
    static func matches(_ line: String, threadID: String, since: Date) -> Bool {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = formatter.string(from: since)
        guard line.count >= 24, String(line.prefix(24)) >= timestamp else { return false }
        guard line.contains("conversationId=\(threadID)") || line.contains("threadId=\(threadID)") else {
            return false
        }
        return line.contains("maybe_resume_success")
            || (line.contains("method=thread/resume") && line.contains("errorCode=null"))
    }
}
