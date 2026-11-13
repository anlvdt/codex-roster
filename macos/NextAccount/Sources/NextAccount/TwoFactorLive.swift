import CryptoKit
import Foundation

/// Credentials entered on the Add Account sheet. Kept in memory for one login
/// only — never written to disk, logs, or the roster snapshot.
struct OpenAILoginCredentials: Equatable {
    var email: String
    var password: String
    var twoFactor: String

    var trimmedEmail: String { email.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedPassword: String { password.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedTwoFactor: String { twoFactor.trimmingCharacters(in: .whitespacesAndNewlines) }

    var hasTwoFactor: Bool { !trimmedTwoFactor.isEmpty }

    var emailLooksValid: Bool {
        let value = trimmedEmail
        guard let at = value.firstIndex(of: "@") else { return false }
        return at > value.startIndex && at < value.index(before: value.endIndex)
    }

    /// Email + password are required to start. A 2fa.live value is optional,
    /// but if present it must parse as a TOTP secret or 2fa.live / otpauth URL.
    var isReadyToStart: Bool {
        emailLooksValid && !trimmedPassword.isEmpty && twoFactorParseError == nil
    }

    var twoFactorParseError: String? {
        guard hasTwoFactor else { return nil }
        if TwoFactorLive.parse(trimmedTwoFactor) == nil {
            return AppLanguage.text(
                "2fa.live không đọc được. Dán secret Base32 hoặc URL 2fa.live / otpauth.",
                "Could not read 2fa.live. Paste a Base32 secret or a 2fa.live / otpauth URL."
            )
        }
        return nil
    }
}

/// 2fa.live-compatible TOTP: local RFC 6238 (SHA-1, 6 digits, 30s).
/// Accepts a raw secret, `https://2fa.live/tok/…`, query/fragment forms, or `otpauth://`.
enum TwoFactorLive {
    struct Secret: Equatable {
        var base32: String
        var period: Int
        var digits: Int
    }

    struct Code: Equatable {
        var value: String
        var remaining: Int
        var period: Int
    }

    static func parse(_ raw: String) -> Secret? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // 4–8 digit SMS / WhatsApp / email OTPs are not 2fa.live secrets.
        if looksLikeDeliveredOTP(trimmed) { return nil }

        if let url = URL(string: trimmed), let fromURL = parseURL(url) {
            return fromURL
        }
        if let otpauth = parseOTPAuth(trimmed) {
            return otpauth
        }
        return decodeSecret(trimmed).map { Secret(base32: $0, period: 30, digits: 6) }
    }

    static func code(from raw: String, at date: Date = .now) -> Code? {
        guard let secret = parse(raw) else { return nil }
        return code(for: secret, at: date)
    }

    static func code(for secret: Secret, at date: Date = .now) -> Code? {
        let period = max(secret.period, 1)
        let epoch = date.timeIntervalSince1970
        let counter = UInt64(epoch / Double(period))
        let remaining = max(1, period - Int(epoch.truncatingRemainder(dividingBy: Double(period))))
        guard let value = totp(secret: secret.base32, counter: counter, digits: secret.digits) else {
            return nil
        }
        return Code(value: value, remaining: remaining, period: period)
    }

    static func isOpenAILoginURL(_ value: String) -> Bool {
        guard let url = URL(string: value), let host = url.host?.lowercased() else { return false }
        if host == "localhost" || host == "127.0.0.1" { return false }
        if host == "auth.openai.com" || host.hasSuffix(".auth.openai.com") { return true }
        if host == "chatgpt.com" || host.hasSuffix(".chatgpt.com") { return true }
        if host == "openai.com" || host.hasSuffix(".openai.com") {
            let path = url.path.lowercased()
            return path.contains("oauth") || path.contains("login") || path.contains("auth")
        }
        return false
    }

    private static func parseURL(_ url: URL) -> Secret? {
        let host = url.host?.lowercased() ?? ""
        let isTwoFALive = host == "2fa.live" || host.hasSuffix(".2fa.live")
            || host == "2falive.net" || host.hasSuffix(".2falive.net")
        guard isTwoFALive || url.scheme?.lowercased() == "otpauth" else {
            if url.scheme == "http" || url.scheme == "https" { return nil }
            return nil
        }
        if url.scheme?.lowercased() == "otpauth" {
            return parseOTPAuth(url.absoluteString)
        }

        var period = 30
        var digits = 6
        var candidate: String?

        if let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems {
            for item in items {
                switch item.name.lowercased() {
                case "secret", "key", "tok", "token":
                    candidate = item.value
                case "period":
                    if let value = item.value.flatMap(Int.init), value > 0 { period = value }
                case "digits":
                    if let value = item.value.flatMap(Int.init), value > 0 { digits = value }
                default:
                    break
                }
            }
        }

        let path = url.path
        if candidate == nil {
            let parts = path.split(separator: "/").map(String.init)
            if let tokIndex = parts.firstIndex(where: { $0.caseInsensitiveCompare("tok") == .orderedSame }),
               tokIndex + 1 < parts.count {
                candidate = parts[tokIndex + 1]
            }
        }

        if candidate == nil, let fragment = url.fragment, !fragment.isEmpty {
            if let fragmentURL = URL(string: "https://2fa.live/\(fragment.hasPrefix("/") ? String(fragment.dropFirst()) : fragment)") {
                return parseURL(fragmentURL)
            }
            if let decoded = decodeSecret(fragment) {
                candidate = decoded
            }
        }

        guard let raw = candidate, let secret = decodeSecret(raw) else { return nil }
        return Secret(base32: secret, period: period, digits: digits)
    }

    private static func parseOTPAuth(_ raw: String) -> Secret? {
        guard raw.lowercased().hasPrefix("otpauth://") else { return nil }
        guard let components = URLComponents(string: raw) else { return nil }
        var period = 30
        var digits = 6
        var secret: String?
        for item in components.queryItems ?? [] {
            switch item.name.lowercased() {
            case "secret":
                secret = item.value
            case "period":
                if let value = item.value.flatMap(Int.init), value > 0 { period = value }
            case "digits":
                if let value = item.value.flatMap(Int.init), value > 0 { digits = value }
            default:
                break
            }
        }
        guard let secret, let decoded = decodeSecret(secret) else { return nil }
        return Secret(base32: decoded, period: period, digits: digits)
    }

    /// WhatsApp / SMS / email one-time codes: 4–8 digits, optional spaces.
    static func looksLikeDeliveredOTP(_ raw: String) -> Bool {
        let compact = raw.filter { !$0.isWhitespace && $0 != "-" }
        guard (4...8).contains(compact.count) else { return false }
        return compact.allSatisfy(\.isNumber)
    }

    static func decodeSecret(_ raw: String) -> String? {
        let compact = raw
            .uppercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "=", with: "")
        guard compact.count >= 8, compact.unicodeScalars.allSatisfy(isBase32Scalar) else {
            return nil
        }
        guard base32Decode(compact) != nil else { return nil }
        return compact
    }

    static func totp(secret: String, counter: UInt64, digits: Int = 6) -> String? {
        guard let key = base32Decode(secret), !key.isEmpty else { return nil }
        var bigEndian = counter.bigEndian
        let message = Data(bytes: &bigEndian, count: MemoryLayout<UInt64>.size)
        let mac = HMAC<Insecure.SHA1>.authenticationCode(for: message, using: SymmetricKey(data: key))
        let bytes = Array(mac)
        guard bytes.count >= 20 else { return nil }
        let offset = Int(bytes[bytes.count - 1] & 0x0F)
        guard offset + 3 < bytes.count else { return nil }
        let binary = (Int(bytes[offset] & 0x7F) << 24)
            | (Int(bytes[offset + 1]) << 16)
            | (Int(bytes[offset + 2]) << 8)
            | Int(bytes[offset + 3])
        let modulus = pow10(min(max(digits, 6), 8))
        return String(format: "%0\(min(max(digits, 6), 8))d", binary % modulus)
    }

    private static func pow10(_ digits: Int) -> Int {
        var value = 1
        for _ in 0..<digits { value *= 10 }
        return value
    }

    private static func isBase32Scalar(_ scalar: Unicode.Scalar) -> Bool {
        ("A"..."Z").contains(Character(scalar)) || ("2"..."7").contains(Character(scalar))
    }

    static func base32Decode(_ raw: String) -> Data? {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var bits = 0
        var value = 0
        var output = Data()
        for character in raw.uppercased() where character != "=" {
            guard let index = alphabet.firstIndex(of: character) else { return nil }
            value = (value << 5) | index
            bits += 5
            if bits >= 8 {
                bits -= 8
                output.append(UInt8((value >> bits) & 0xFF))
            }
        }
        return output
    }
}
