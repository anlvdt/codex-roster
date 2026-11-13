import Foundation
import Testing
@testable import CodexRoster

@Test func nativeQueueProtectsUserIntentAndDeduplicatesRoster() throws {
    let id = "thread-a"
    func state(_ messages: Any) throws -> CodexResumePolicy.QueueState {
        CodexResumePolicy.queueState(
            data: try JSONSerialization.data(withJSONObject: ["queued-follow-ups": [id: messages]]),
            threadID: id
        )
    }
    #expect(try state([]) == .empty)
    let own = ["text": CodexResumePolicy.message(id)]
    #expect(try state([own]) == .owned)
    // Duplicate Roster continues (re-queue after failed Resume) stay owned.
    #expect(try state([own, own]) == .owned)
    #expect(try state([["text": CodexResumePolicy.message("thread-b")]]) == .blocked)
    #expect(try state([["text": "My draft"]]) == .blocked)
    #expect(try state([["text": CodexResumePolicy.continuation]]) == .blocked)
    #expect(try state([own, ["text": "My draft"]]) == .blocked)
    #expect(try state("new unknown format") == .unavailable)
    #expect(CodexResumePolicy.queueState(data: Data("{}".utf8), threadID: id) == .unavailable)
    #expect(CodexResumePolicy.queueState(data: Data("invalid".utf8), threadID: id) == .unavailable)
}

@Test func sqliteQueuePayloadsClassifyLikeJSON() {
    let id = "01a1d2af-35d0-7130-8398-0e057a0d924b"
    let owned = """
    {"UserInput":{"content":[{"type":"text","text":"\(CodexResumePolicy.message(id))"}]}}
    """
    let foreign = """
    {"UserInput":{"content":[{"type":"text","text":"user draft"}]}}
    """
    #expect(CodexResumePolicy.classifyPayloadTexts([], threadID: id) == .empty)
    #expect(CodexResumePolicy.classifyPayloadTexts([owned], threadID: id) == .owned)
    #expect(CodexResumePolicy.classifyPayloadTexts([owned, owned], threadID: id) == .owned)
    #expect(CodexResumePolicy.classifyPayloadTexts([owned, foreign], threadID: id) == .blocked)
    #expect(CodexResumePolicy.classifyPayloadTexts([foreign], threadID: id) == .blocked)
}

@Test func resumeMatcherExcludesSendStopAndUnrelatedControls() {
    #expect(CodexResumePolicy.isResumeLabel("Resume"))
    #expect(CodexResumePolicy.isResumeLabel("Tiếp tục"))
    for label in ["Send", "Stop", "Resume session settings", "Play music", "Run now", ""] {
        #expect(!CodexResumePolicy.isResumeLabel(label))
    }
}
