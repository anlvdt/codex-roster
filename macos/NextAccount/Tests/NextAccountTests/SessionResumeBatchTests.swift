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
