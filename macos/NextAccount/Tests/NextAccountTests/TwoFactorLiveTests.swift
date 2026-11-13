import Foundation
import Testing
@testable import CodexRoster

@Test func twoFactorLiveParsesRawSecretAndKnownURLs() {
    let secret = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"
    #expect(TwoFactorLive.parse(secret)?.base32 == secret)
    #expect(TwoFactorLive.parse("gez dgnb vgy3 tqoj qgez dgnb vgy3 tqoj q")?.base32 == secret)
    #expect(TwoFactorLive.parse("https://2fa.live/tok/\(secret)")?.base32 == secret)
    #expect(TwoFactorLive.parse("https://2fa.live/?secret=\(secret)")?.base32 == secret)
    #expect(TwoFactorLive.parse("https://2fa.live/#/tok/\(secret)")?.base32 == secret)
    #expect(TwoFactorLive.parse("otpauth://totp/Example?secret=\(secret)&period=30")?.base32 == secret)
    #expect(TwoFactorLive.parse("https://evil.example/tok/\(secret)") == nil)
    #expect(TwoFactorLive.parse("hello!") == nil)
    #expect(TwoFactorLive.parse("short") == nil)
    #expect(TwoFactorLive.parse("847291") == nil)
    #expect(TwoFactorLive.parse("12 34 56") == nil)
    #expect(TwoFactorLive.looksLikeDeliveredOTP("123456"))
    #expect(TwoFactorLive.looksLikeDeliveredOTP("847 291"))
    #expect(!TwoFactorLive.looksLikeDeliveredOTP(secret))
}

@Test func twoFactorLiveMatchesRfc6238Sha1SixDigits() {
    // RFC 6238 Appendix B, secret ASCII "12345678901234567890".
    let secret = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"
    let parsed = TwoFactorLive.parse(secret)
    #expect(parsed != nil)
    let date = Date(timeIntervalSince1970: 59)
    #expect(TwoFactorLive.code(for: parsed!, at: date)?.value == "287082")
}

@Test func openAILoginCredentialsRequireEmailPasswordAndValidOptionalTwoFactor() {
    #expect(!OpenAILoginCredentials(email: "user", password: "secret", twoFactor: "").isReadyToStart)
    #expect(!OpenAILoginCredentials(email: "user@example.com", password: "", twoFactor: "").isReadyToStart)
    #expect(OpenAILoginCredentials(email: "user@example.com", password: "secret", twoFactor: "").isReadyToStart)
    #expect(OpenAILoginCredentials(
        email: "user@example.com",
        password: "secret",
        twoFactor: "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"
    ).isReadyToStart)
    #expect(!OpenAILoginCredentials(email: "user@example.com", password: "secret", twoFactor: "??").isReadyToStart)
}

@Test func openAILoginURLMatcherAcceptsAuthHostsAndSkipsLoopback() {
    #expect(TwoFactorLive.isOpenAILoginURL("https://auth.openai.com/oauth/authorize?client_id=1"))
    #expect(TwoFactorLive.isOpenAILoginURL("https://chatgpt.com/auth/login"))
    #expect(TwoFactorLive.isOpenAILoginURL("https://openai.com/oauth/authorize"))
    #expect(!TwoFactorLive.isOpenAILoginURL("http://localhost:1455/auth/callback"))
    #expect(!TwoFactorLive.isOpenAILoginURL("http://127.0.0.1:1457/success"))
    #expect(!TwoFactorLive.isOpenAILoginURL("https://example.com/login"))
}

@Test func openInterceptorScriptQuotesPathsAndStealsOnlyOpenAIURLs() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("codex-roster-open-tests-\(UUID().uuidString)", isDirectory: true)
    let bin = root.appendingPathComponent("bin", isDirectory: true)
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    let urlFile = root.appendingPathComponent("oauth-url.txt")
    try ChromePrivateLoginSession.writeOpenInterceptor(to: bin, urlFile: urlFile)
    let script = bin.appendingPathComponent("open")
    #expect(FileManager.default.isExecutableFile(atPath: script.path))

    let process = Process()
    process.executableURL = script
    process.arguments = ["https://auth.openai.com/oauth/authorize?client_id=1"]
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    let captured = try String(contentsOf: urlFile, encoding: .utf8)
    #expect(captured.contains("auth.openai.com"))

    try? FileManager.default.removeItem(at: root)
}

@Test func openAILoginFillScriptEmbedsCredentialsWithoutRawConcatenation() {
    let js = OpenAILoginFillScript.make(
        email: "user@example.com",
        password: "p@ss\"word",
        otp: "123456"
    )
    #expect(js.contains("user@example.com"))
    #expect(js.contains("123456"))
    #expect(js.contains("\\\\\"") || js.contains("\\\"") || js.contains("p@ss"))
    #expect(js.contains("current-password"))
}

@Test func openAILoginFillScriptDoesNotTreatWhatsAppOrSmsOtpAsAuthenticator() {
    let js = OpenAILoginFillScript.make(email: "a@b.co", password: "x", otp: "999111")
    #expect(js.contains("deliveredOtpPage"))
    #expect(js.contains("authenticatorPage"))
    #expect(js.contains("skip-delivered-otp"))
    #expect(js.contains("whatsapp"))
    #expect(js.contains("try-another-method"))
    #expect(!js.contains("input[inputmode=numeric]"))
    #expect(!js.contains("input[id*=code i]"))
    // TOTP is only filled on authenticator pages, never blindly into one-time-code.
    #expect(js.contains("if (c.otp && authenticatorPage)"))
}
