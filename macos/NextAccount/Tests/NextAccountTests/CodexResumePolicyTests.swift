import Foundation
import Testing
@testable import CodexRoster

@Test func nativeQueueProtectsUserIntentAndDeduplicatesRoster() throws {
    let id = "thread-a"
    func state(_ messages: Any) throws -> CodexResumePolicy.QueueState {
        CodexResumePolicy.queueState(data: try JSONSerialization.data(withJSONObject: ["queued-follow-ups": [id: messages]]), threadID: id)
    }
    #expect(try state([]) == .empty)
    let own = ["text": CodexResumePolicy.message(id)]
    #expect(try state([own]) == .owned)
    #expect(try state([["text": CodexResumePolicy.message("thread-b")]]) == .blocked)
    #expect(try state([["text": "My draft"]]) == .blocked)
    #expect(try state([["text": CodexResumePolicy.continuation]]) == .blocked)
    #expect(try state([own, ["text": "My draft"]]) == .blocked)
    #expect(try state("new unknown format") == .unavailable)
    #expect(CodexResumePolicy.queueState(data: Data("{}".utf8), threadID: id) == .unavailable)
    #expect(CodexResumePolicy.queueState(data: Data("invalid".utf8), threadID: id) == .unavailable)
}

@Test func resumeMatcherExcludesSendStopAndUnrelatedControls() {
    #expect(CodexResumePolicy.isResumeLabel("Resume"))
    #expect(CodexResumePolicy.isResumeLabel("Tiếp tục"))
    for label in ["Send", "Stop", "Resume session settings", "Play music", "Run now", ""] {
        #expect(!CodexResumePolicy.isResumeLabel(label))
    }
}
