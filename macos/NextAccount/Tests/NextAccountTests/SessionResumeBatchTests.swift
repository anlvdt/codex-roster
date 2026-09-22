import Foundation
import Testing
@testable import CodexRoster

@Test @MainActor func resumeBatchContinuesAfterFailureAndDeduplicates() async {
    var calls: [String] = []
    let result = await SessionResumeBatch.run(
        threadIDs: ["one", "one", "", "two", "three"],
        shouldContinue: { true },
        progress: { _, _ in },
        enqueue: { id in calls.append(id); return id != "two" }
    )
    #expect(calls == ["one", "two", "three"])
    #expect(result.total == 3)
    #expect(result.succeeded == 2)
}

@Test @MainActor func resumeBatchStopsWhenDisabledBetweenThreads() async {
    var calls: [String] = []
    let result = await SessionResumeBatch.run(
        threadIDs: ["one", "two"],
        shouldContinue: { calls.isEmpty },
        progress: { _, _ in },
        enqueue: { id in calls.append(id); return true }
    )
    #expect(calls == ["one"])
    #expect(result.succeeded == 1)
    #expect(result.total == 2)
}

@Test func desktopResumeEvidenceRequiresFreshSuccessForExactThread() {
    let since = ISO8601DateFormatter().date(from: "2026-09-23T10:00:00Z")!
    let old = "2026-09-23T09:59:59.000Z info maybe_resume_success conversationId=one"
    let fresh = "2026-09-23T10:00:01.000Z info maybe_resume_success conversationId=one"
    let other = "2026-09-23T10:00:02.000Z info maybe_resume_success conversationId=two"
    let failure = "2026-09-23T10:00:03.000Z info method=thread/resume conversationId=one errorCode=failed"
    let response = "2026-09-23T10:00:04.000Z info method=thread/resume conversationId=one errorCode=null"
    #expect(!DesktopResumeEvidence.matches(old, threadID: "one", since: since))
    #expect(DesktopResumeEvidence.matches(fresh, threadID: "one", since: since))
    #expect(!DesktopResumeEvidence.matches(other, threadID: "one", since: since))
    #expect(!DesktopResumeEvidence.matches(failure, threadID: "one", since: since))
    #expect(DesktopResumeEvidence.matches(response, threadID: "one", since: since))
}
