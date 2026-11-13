import Darwin
import Foundation

/// Isolated Chrome Incognito window for one `codex login`.
/// A unique `--user-data-dir` is required: Chrome shares cookies across every
/// Incognito tab of the same profile, so a plain private tab would leak the
/// previous account into the next add.
@MainActor
final class ChromePrivateLoginSession {
    private let workDirectory: URL
    private let urlFile: URL
    let openInterceptorDirectory: URL
    private let profileDirectory: URL
    private let debugPort: UInt16
    private let chromePath: String
    private let credentials: OpenAILoginCredentials?
    private var chromeProcess: Process?
    private var watchTask: Task<Void, Never>?
    private var fillTask: Task<Void, Never>?
    private var cdp: ChromeDevToolsClient?
    private(set) var phaseMessage: String?
    var onPhase: ((String?) -> Void)?

    static func chromeExecutablePath() -> String? {
        let environment = ProcessInfo.processInfo.environment
        let candidates = [
            environment["CODEX_ROSTER_CHROME_PATH"],
            "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
            "/Applications/Google Chrome Canary.app/Contents/MacOS/Google Chrome Canary",
            "/Applications/Chromium.app/Contents/MacOS/Chromium",
            "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser"
        ]
        return candidates
            .compactMap { $0 }
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    }

    static func begin(credentials: OpenAILoginCredentials?) throws -> ChromePrivateLoginSession {
        guard let chromePath = chromeExecutablePath() else {
            throw ChromePrivateLoginError.chromeMissing
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-roster-chrome-login", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let interceptor = root.appendingPathComponent("bin", isDirectory: true)
        let profile = root.appendingPathComponent("profile", isDirectory: true)
        try FileManager.default.createDirectory(at: interceptor, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        let urlFile = root.appendingPathComponent("oauth-url.txt")
        try Self.writeOpenInterceptor(to: interceptor, urlFile: urlFile)
        let session = ChromePrivateLoginSession(
            workDirectory: root,
            urlFile: urlFile,
            openInterceptorDirectory: interceptor,
            profileDirectory: profile,
            debugPort: try ephemeralLoopbackPort(),
            chromePath: chromePath,
            credentials: credentials
        )
        return session
    }

    private init(
        workDirectory: URL,
        urlFile: URL,
        openInterceptorDirectory: URL,
        profileDirectory: URL,
        debugPort: UInt16,
        chromePath: String,
        credentials: OpenAILoginCredentials?
    ) {
        self.workDirectory = workDirectory
        self.urlFile = urlFile
        self.openInterceptorDirectory = openInterceptorDirectory
        self.profileDirectory = profileDirectory
        self.debugPort = debugPort
        self.chromePath = chromePath
        self.credentials = credentials
    }

    var pathPrefix: String { openInterceptorDirectory.path }

    func noteLoginURL(_ url: String) {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard TwoFactorLive.isOpenAILoginURL(trimmed) else { return }
        try? trimmed.write(to: urlFile, atomically: true, encoding: .utf8)
    }

    func startWatching() {
        watchTask?.cancel()
        publish(AppLanguage.text(
            "Đang chờ Codex mở URL đăng nhập…",
            "Waiting for Codex to open the sign-in URL…"
        ))
        watchTask = Task { [weak self] in
            guard let self else { return }
            var lastURL = ""
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled else { return }
                guard let raw = try? String(contentsOf: self.urlFile, encoding: .utf8) else { continue }
                let url = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !url.isEmpty, url != lastURL else { continue }
                lastURL = url
                do {
                    try self.openPrivateWindow(url: url)
                    self.startFillingIfNeeded()
                } catch {
                    Diagnostics.logFailure("open Chrome private login", error)
                    self.publish(error.localizedDescription)
                }
            }
        }
    }

    func stop() {
        watchTask?.cancel()
        watchTask = nil
        fillTask?.cancel()
        fillTask = nil
        cdp?.close()
        cdp = nil
        if let chromeProcess, chromeProcess.isRunning {
            chromeProcess.terminate()
        }
        chromeProcess = nil
        publish(nil)
        Diagnostics.removeIfPresent(workDirectory, operation: "remove Chrome private login profile")
    }

    private func openPrivateWindow(url: String) throws {
        if let chromeProcess, chromeProcess.isRunning {
            // Same isolated Chrome instance: open another private tab via CDP if possible.
            Task { try? await self.cdp?.openURL(url) }
            return
        }
        publish(AppLanguage.text(
            "Đang mở tab riêng tư Chrome…",
            "Opening a Chrome private tab…"
        ))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: chromePath)
        process.arguments = [
            "--user-data-dir=\(profileDirectory.path)",
            "--incognito",
            "--new-window",
            "--no-first-run",
            "--no-default-browser-check",
            "--disable-extensions",
            "--disable-sync",
            "--disable-features=Translate,MediaRouter",
            "--remote-debugging-address=127.0.0.1",
            "--remote-debugging-port=\(debugPort)",
            "--remote-allow-origins=*",
            url
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        chromeProcess = process
    }

    private func startFillingIfNeeded() {
        guard fillTask == nil else { return }
        fillTask = Task { [weak self] in
            guard let self else { return }
            let client = ChromeDevToolsClient(port: self.debugPort)
            self.cdp = client
            for _ in 0..<50 {
                if Task.isCancelled { return }
                if await client.waitUntilReady() { break }
                try? await Task.sleep(for: .milliseconds(200))
            }
            guard await client.waitUntilReady() else {
                self.publish(AppLanguage.text(
                    "Chrome đã mở — hãy hoàn tất đăng nhập trong tab riêng tư.",
                    "Chrome is open — finish signing in in the private tab."
                ))
                return
            }
            guard let credentials = self.credentials, credentials.isReadyToStart else {
                self.publish(AppLanguage.text(
                    "Hãy đăng nhập trong tab Chrome riêng tư vừa mở.",
                    "Sign in in the Chrome private tab that just opened."
                ))
                return
            }
            self.publish(AppLanguage.text(
                "Đang điền email / mật khẩu / 2FA trên tab riêng tư…",
                "Filling email / password / 2FA in the private tab…"
            ))
            var lastStep = ""
            while !Task.isCancelled {
                let code: String
                if credentials.hasTwoFactor,
                   let totp = TwoFactorLive.code(from: credentials.trimmedTwoFactor) {
                    if totp.remaining <= 2 {
                        try? await Task.sleep(for: .milliseconds(800))
                        continue
                    }
                    code = totp.value
                } else {
                    code = ""
                }
                let step = (try? await client.fillOpenAILogin(
                    email: credentials.trimmedEmail,
                    password: credentials.trimmedPassword,
                    otp: code
                )) ?? "waiting"
                if step != lastStep {
                    lastStep = step
                    self.publish(Self.phaseText(for: step))
                }
                if step == "callback" || step == "done" {
                    self.publish(AppLanguage.text(
                        "OpenAI đã chuyển về Codex. Đang chờ auth.json…",
                        "OpenAI redirected back to Codex. Waiting for auth.json…"
                    ))
                    return
                }
                try? await Task.sleep(for: .milliseconds(700))
            }
        }
    }

    private static func phaseText(for step: String) -> String {
        switch step {
        case "email":
            return AppLanguage.text("Đã điền email — đang tiếp tục…", "Filled email — continuing…")
        case "password":
            return AppLanguage.text("Đã điền mật khẩu — đang tiếp tục…", "Filled password — continuing…")
        case "otp", "totp":
            return AppLanguage.text("Đã điền mã authenticator 2FA — đang xác minh…", "Filled authenticator 2FA — verifying…")
        case "password-method":
            return AppLanguage.text("Đang chọn đăng nhập bằng mật khẩu…", "Choosing password sign-in…")
        case "2fa-method":
            return AppLanguage.text("Đang chọn ứng dụng xác thực (không dùng WhatsApp/SMS)…", "Choosing authenticator app (not WhatsApp/SMS)…")
        case "try-another-method":
            return AppLanguage.text("Bỏ qua WhatsApp/SMS OTP — chuyển sang authenticator…", "Skipping WhatsApp/SMS OTP — switching to authenticator…")
        case "skip-delivered-otp":
            return AppLanguage.text(
                "Trang đang hỏi mã WhatsApp/SMS/email — không điền 2FA. Chọn Authenticator nếu có.",
                "This page wants a WhatsApp/SMS/email code — not filling 2FA. Choose Authenticator if shown."
            )
        case "waiting":
            return AppLanguage.text(
                "Đang chờ form OpenAI trên tab riêng tư…",
                "Waiting for the OpenAI form in the private tab…"
            )
        default:
            return AppLanguage.text(
                "Hãy hoàn tất bước còn lại trong tab Chrome riêng tư.",
                "Finish any remaining step in the Chrome private tab."
            )
        }
    }

    private func publish(_ message: String?) {
        phaseMessage = message
        onPhase?(message)
    }

    nonisolated static func writeOpenInterceptor(to directory: URL, urlFile: URL) throws {
        let script = directory.appendingPathComponent("open")
        let body = """
        #!/bin/bash
        url=""
        for arg in "$@"; do
          case "$arg" in
            http://*|https://*) url="$arg" ;;
          esac
        done
        if [ -n "$url" ]; then
          case "$url" in
            *auth.openai.com*|*chatgpt.com*|*openai.com/oauth*|*openai.com/login*|*openai.com/auth*)
              printf '%s' "$url" > \(shellSingleQuote(urlFile.path))
              exit 0
              ;;
          esac
        fi
        exec /usr/bin/open "$@"
        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    }

    nonisolated static func shellSingleQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

enum ChromePrivateLoginError: LocalizedError {
    case chromeMissing

    var errorDescription: String? {
        switch self {
        case .chromeMissing:
            return AppLanguage.text(
                "Không tìm thấy Google Chrome. Cài Chrome để thêm tài khoản bằng tab riêng tư.",
                "Google Chrome was not found. Install Chrome to add accounts in a private tab."
            )
        }
    }
}

func ephemeralLoopbackPort() throws -> UInt16 {
    let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
    guard fd >= 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [
            NSLocalizedDescriptionKey: "Could not allocate a Chrome debugging port."
        ])
    }
    defer { close(fd) }
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    addr.sin_port = 0
    let bindResult = withUnsafePointer(to: &addr) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
            bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bindResult == 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [
            NSLocalizedDescriptionKey: "Could not bind a Chrome debugging port."
        ])
    }
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let nameResult = withUnsafeMutablePointer(to: &addr) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
            getsockname(fd, sockaddrPointer, &length)
        }
    }
    guard nameResult == 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [
            NSLocalizedDescriptionKey: "Could not read the Chrome debugging port."
        ])
    }
    return UInt16(bigEndian: addr.sin_port)
}

/// Minimal Chrome DevTools client for the isolated login window.
final class ChromeDevToolsClient: @unchecked Sendable {
    private let port: UInt16
    private let session: URLSession
    private var webSocket: URLSessionWebSocketTask?
    private var nextID = 1
    private let lock = NSLock()

    init(port: UInt16) {
        self.port = port
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    func waitUntilReady() async -> Bool {
        (try? await listTargets())?.isEmpty == false
    }

    func openURL(_ url: String) async throws {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = Int(port)
        components.path = "/json/new"
        components.query = url
        guard let endpoint = components.url else { return }
        _ = try await session.data(from: endpoint)
    }

    func fillOpenAILogin(email: String, password: String, otp: String) async throws -> String {
        guard let target = try await preferredTarget() else { return "waiting" }
        if isCallbackURL(target.url) { return "callback" }
        try await attach(to: target, force: false)
        let expression = OpenAILoginFillScript.make(email: email, password: password, otp: otp)
        let result: [String: Any]
        do {
            result = try await send(
                method: "Runtime.evaluate",
                params: [
                    "expression": expression,
                    "returnByValue": true,
                    "awaitPromise": false
                ]
            )
        } catch {
            try await attach(to: target, force: true)
            result = try await send(
                method: "Runtime.evaluate",
                params: [
                    "expression": expression,
                    "returnByValue": true,
                    "awaitPromise": false
                ]
            )
        }
        if let value = result["result"] as? [String: Any],
           let step = value["value"] as? String {
            return step
        }
        return "waiting"
    }

    func close() {
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        session.invalidateAndCancel()
    }

    private struct Target {
        var id: String
        var url: String
        var webSocketDebuggerURL: URL
    }

    private func preferredTarget() async throws -> Target? {
        let targets = try await listTargets()
        if let match = targets.first(where: { TwoFactorLive.isOpenAILoginURL($0.url) || isCallbackURL($0.url) }) {
            return match
        }
        return targets.first
    }

    private func isCallbackURL(_ value: String) -> Bool {
        guard let url = URL(string: value), let host = url.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1"
    }

    private func listTargets() async throws -> [Target] {
        guard let endpoint = URL(string: "http://127.0.0.1:\(port)/json/list") else { return [] }
        let (data, _) = try await session.data(from: endpoint)
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let socket = (row["webSocketDebuggerUrl"] as? String).flatMap(URL.init(string:)) else {
                return nil
            }
            return Target(
                id: row["id"] as? String ?? "",
                url: row["url"] as? String ?? "",
                webSocketDebuggerURL: socket
            )
        }
    }

    private func attach(to target: Target, force: Bool) async throws {
        if webSocket != nil && !force { return }
        webSocket?.cancel(with: .goingAway, reason: nil)
        let task = session.webSocketTask(with: target.webSocketDebuggerURL)
        task.resume()
        webSocket = task
        _ = try await send(method: "Runtime.enable", params: [:])
    }

    private func send(method: String, params: [String: Any]) async throws -> [String: Any] {
        let id: Int = {
            lock.lock()
            defer { lock.unlock() }
            let value = nextID
            nextID += 1
            return value
        }()
        let payload: [String: Any] = [
            "id": id,
            "method": method,
            "params": params
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard let text = String(data: data, encoding: .utf8) else {
            throw URLError(.cannotDecodeContentData)
        }
        guard let webSocket else {
            throw URLError(.badServerResponse)
        }
        try await webSocket.send(.string(text))
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            let message = try await webSocket.receive()
            let raw: Data
            switch message {
            case .string(let string):
                raw = Data(string.utf8)
            case .data(let data):
                raw = data
            @unknown default:
                continue
            }
            guard let object = try JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
                continue
            }
            if let echoed = object["id"] as? Int, echoed == id {
                if let error = object["error"] as? [String: Any] {
                    throw NSError(domain: "ChromeDevTools", code: 1, userInfo: [
                        NSLocalizedDescriptionKey: (error["message"] as? String) ?? "Chrome DevTools error"
                    ])
                }
                return object
            }
        }
        throw URLError(.timedOut)
    }
}

enum OpenAILoginFillScript {
    static func make(email: String, password: String, otp: String) -> String {
        let payload: [String: String] = [
            "email": email,
            "password": password,
            "otp": otp
        ]
        let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
        let json = String(data: data, encoding: .utf8) ?? "{}"
        return """
        (() => {
          const c = \(json);
          const visible = (el) => !!(el && el.offsetParent !== null && !el.disabled);
          const textOf = (el) => ((el && (el.innerText || el.textContent || el.value || el.placeholder || el.getAttribute?.("aria-label") || "")) + "").toLowerCase();
          const contextOf = (el) => {
            const bits = [textOf(el), el?.name, el?.id, el?.autocomplete, el?.getAttribute?.("aria-label")];
            const label = el?.labels && el.labels[0] ? textOf(el.labels[0]) : "";
            const parent = el?.closest ? textOf(el.closest("label, [role=group], form, section")) : "";
            bits.push(label, parent);
            return bits.filter(Boolean).join(" ");
          };
          const first = (sels) => {
            for (const sel of sels) {
              const el = document.querySelector(sel);
              if (visible(el)) return el;
            }
            return null;
          };
          const setNative = (el, value) => {
            const proto = el instanceof HTMLTextAreaElement
              ? HTMLTextAreaElement.prototype
              : HTMLInputElement.prototype;
            const desc = Object.getOwnPropertyDescriptor(proto, "value");
            if (desc && desc.set) desc.set.call(el, value);
            else el.value = value;
            el.dispatchEvent(new Event("input", { bubbles: true }));
            el.dispatchEvent(new Event("change", { bubbles: true }));
          };
          const clickSubmit = () => {
            const buttons = Array.from(document.querySelectorAll("button, [type=submit]"));
            const named = buttons.find((b) => /continue|next|verify|submit|log in|sign in|tiếp|đăng nhập|xác minh/i.test(textOf(b)));
            const fallback = document.querySelector("button[type=submit]") || buttons.find((b) => !b.disabled);
            const btn = named || fallback;
            if (btn && !btn.disabled) btn.click();
          };
          const clickables = () => Array.from(document.querySelectorAll("button, a, [role=button], [role=radio], [role=option], label"));
          if (/localhost|127\\.0\\.0\\.1/.test(location.hostname || "")) return "callback";

          const pageText = textOf(document.body);
          const deliveredOtpPage = /whatsapp|whats\\s*app|text message|\\bsms\\b|tin nhắn|số điện thoại|phone number|gửi mã|sent a (6-digit )?code|code (was )?sent to your (phone|email|whatsapp)|we (texted|emailed|sent) you a code|one-time password|otp (to|via) (sms|email|whatsapp)/i.test(pageText);
          const authenticatorPage = /authenticator|authentication app|google authenticator|authy|totp|ứng dụng xác thực|enter (the )?(code|otp) from your authenticator/i.test(pageText);
          const deliveredField = (el) => /whatsapp|whats\\s*app|\\bsms\\b|text message|phone|email.?code|tin nhắn/i.test(contextOf(el));
          const authenticatorChoice = clickables().find((el) =>
            /authenticator|authentication app|ứng dụng xác thực/i.test(textOf(el)) &&
            !/whatsapp|\\bsms\\b|text message|email code/i.test(textOf(el))
          );
          const tryAnother = clickables().find((el) =>
            /try another method|try a different method|use (a )?different method|phương thức khác|cách khác/i.test(textOf(el))
          );

          if (authenticatorChoice && !authenticatorPage) {
            authenticatorChoice.click();
            return "2fa-method";
          }
          if (deliveredOtpPage && !authenticatorPage && tryAnother) {
            tryAnother.click();
            return "try-another-method";
          }

          const emailEl = first([
            "input[type=email]",
            "input[name=email]",
            "input[name=username]",
            "input[autocomplete=username]",
            "input[id=email-input]",
            "input[id*=email i]"
          ]);
          if (emailEl) {
            setNative(emailEl, c.email);
            clickSubmit();
            return "email";
          }
          const passEl = first([
            "input[type=password]",
            "input[name=password]",
            "input[autocomplete=current-password]"
          ]);
          if (passEl) {
            setNative(passEl, c.password);
            clickSubmit();
            return "password";
          }
          const passwordMethod = clickables().find((el) =>
            /use (your )?password|email and password|mật khẩu/i.test(textOf(el)) &&
            !/one-time|otp|whatsapp|sms/i.test(textOf(el))
          );
          if (passwordMethod) {
            passwordMethod.click();
            return "password-method";
          }

          const splitOtp = Array.from(document.querySelectorAll("input[maxlength='1']")).filter(visible);
          if (splitOtp.length >= 4 && !authenticatorPage) {
            if (tryAnother) {
              tryAnother.click();
              return "try-another-method";
            }
            return "skip-delivered-otp";
          }

          if (c.otp && authenticatorPage) {
            const totpEl = first([
              "input[autocomplete=one-time-code]",
              "input[name=code]",
              "input[name=otp]",
              "input[name=totp]",
              "input[id*=totp i]",
              "input[id*=authenticator i]"
            ]);
            if (totpEl && !deliveredField(totpEl)) {
              setNative(totpEl, c.otp);
              clickSubmit();
              return "totp";
            }
          }
          if ((deliveredOtpPage || splitOtp.length >= 4) && !authenticatorPage) {
            return "skip-delivered-otp";
          }
          return "waiting";
        })()
        """
    }
}
