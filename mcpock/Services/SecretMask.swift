import Foundation

/// Masks anything that could be a secret before it leaves the app in the
/// status file (round 7). Env and header **values** never get that far (the
/// snapshot carries names only); this handles the places a secret can still
/// hide: command-line arguments (`--api-key sk-…`, `--header "Authorization:
/// Bearer …"`, `TOKEN=…`), URLs (passwords, query values, token-like path
/// segments) and failure texts (a server that echoes its key into stderr).
///
/// Errs on the side of masking: a masked non-secret costs a little context,
/// a leaked key costs a rotation. Pure; `SecretMaskTests` pins it down.
enum SecretMask {
    static let dots = "\u{2022}\u{2022}\u{2022}\u{2022}"

    /// Words that make a flag, env-style name, query key or header secret-ish.
    private static let secretWords = [
        "key", "token", "secret", "password", "passwd", "pwd", "auth", "bearer",
        "credential", "cookie", "session", "private", "signature", "access",
    ]

    /// Prefixes of well-known API key formats.
    private static let tokenPrefixes = [
        "sk-", "sk_", "pk_", "rk_", "ghp_", "gho_", "ghu_", "ghs_", "ghr_", "github_pat_",
        "glpat-", "xoxb-", "xoxp-", "xoxa-", "xoxs-", "ntn_",
        "secret_", "lin_api_", "pplx-", "gsk_", "hf_", "r8_", "tvly-", "fc-", "sq0",
        "shpat_", "shpss_", "whsec_", "npm_", "dop_v1_", "sg.",
    ]

    /// Prefixes that only mean "key" in their exact case (AWS, Google, JWT).
    private static let exactPrefixes = ["AKIA", "ASIA", "AIza", "eyJ"]

    static func isSecretName(_ name: String) -> Bool {
        let lower = name.lowercased()
        return secretWords.contains { lower.contains($0) }
    }

    /// A word that looks like a credential on its own: a known key prefix, or a
    /// long run of letters and digits with no path or URL punctuation.
    static func looksLikeToken(_ word: String) -> Bool {
        let lower = word.lowercased()
        if word.count >= 16, tokenPrefixes.contains(where: { lower.hasPrefix($0) })
            || exactPrefixes.contains(where: { word.hasPrefix($0) }) {
            return true
        }
        guard word.count >= 32 else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_+=."))
        guard word.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        let hasDigit = word.contains { $0.isNumber }
        let hasLetter = word.contains { $0.isLetter }
        return hasDigit && hasLetter
    }

    // MARK: - Command lines

    /// The command line as mcpock shows it (`ServerConfig.commandLine`), with
    /// every secret-looking argument masked. `known` = values that must never
    /// appear (the config's env and header values), masked wherever they occur.
    static func commandLine(command: String?, args: [String], known: [String] = []) -> String {
        var out: [String] = []
        if let command, !command.isEmpty { out.append(scrub(command, known: known)) }
        var previous: String?
        for arg in args {
            out.append(maskArgument(arg, after: previous, known: known))
            previous = arg
        }
        return out.joined(separator: " ")
    }

    static func maskArgument(_ arg: String, after previous: String?, known: [String] = []) -> String {
        // The value after a secret flag: `--api-key sk-…`, `-k …`, `--token …`.
        if let previous, previous.hasPrefix("-"), !previous.contains("="), !arg.hasPrefix("-") {
            let flag = previous.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            if ["header", "headers", "h"].contains(flag.lowercased()) {
                return maskHeaderLine(arg)
            }
            if isSecretName(flag) || flag == "k" { return dots }
        }
        // `--api-key=sk-…`, `--url=https://…?key=…`.
        if arg.hasPrefix("-"), let eq = arg.firstIndex(of: "=") {
            let flag = String(arg[..<eq])
            let value = String(arg[arg.index(after: eq)...])
            if isSecretName(flag) { return flag + "=" + dots }
            if flag.trimmingCharacters(in: CharacterSet(charactersIn: "-")).lowercased().hasPrefix("header") {
                return flag + "=" + maskHeaderLine(value)
            }
            return flag + "=" + maskValue(value, known: known)
        }
        // `API_KEY=…` (env-style, as `env` or a wrapper script takes them).
        if !arg.hasPrefix("-"), let eq = arg.firstIndex(of: "="),
           arg[..<eq].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }), eq != arg.startIndex {
            let name = String(arg[..<eq])
            if isSecretName(name) { return name + "=" + dots }
        }
        // `Authorization: Bearer …` passed on its own.
        if let colon = arg.firstIndex(of: ":"), !arg.contains("://"),
           isSecretName(String(arg[..<colon])) {
            return maskHeaderLine(arg)
        }
        return maskValue(arg, known: known)
    }

    /// One value: a URL is masked as a URL, a token-looking word entirely,
    /// anything else only where a known secret appears in it.
    private static func maskValue(_ value: String, known: [String]) -> String {
        if value.contains("://") { return url(value, known: known) }
        if looksLikeToken(value) { return dots }
        return scrub(value, known: known)
    }

    /// `Authorization: Bearer abc` → `Authorization: ••••`. Every header value
    /// is masked, as in the detail card.
    static func maskHeaderLine(_ line: String) -> String {
        guard let colon = line.firstIndex(of: ":") else { return dots }
        let name = line[..<colon].trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? dots : "\(name): \(dots)"
    }

    // MARK: - URLs

    /// A URL with its password (and a lone user, often a token), every query
    /// value and any token-like path segment masked. Host and path stay: they
    /// are what an agent needs to fix a wrong address.
    static func url(_ text: String, known: [String] = []) -> String {
        guard var parts = URLComponents(string: text), parts.scheme != nil else {
            return scrub(text, known: known)
        }
        if parts.password != nil {
            parts.password = dots
        } else if let user = parts.user, !user.isEmpty {
            parts.user = dots
        }
        if let items = parts.queryItems, !items.isEmpty {
            parts.queryItems = items.map { URLQueryItem(name: $0.name, value: $0.value == nil ? nil : dots) }
        }
        if !parts.path.isEmpty {
            let segments = parts.path.split(separator: "/", omittingEmptySubsequences: false).map { segment -> String in
                let text = String(segment)
                return looksLikeToken(text) || known.contains(where: { isKnown($0) && text.contains($0) }) ? dots : text
            }
            parts.path = segments.joined(separator: "/")
        }
        if let fragment = parts.fragment, !fragment.isEmpty { parts.fragment = dots }
        // URLComponents percent-encodes the dots; show them as written.
        return (parts.string ?? text).removingPercentEncoding ?? (parts.string ?? text)
    }

    // MARK: - Free text

    /// Free text (a failure reason, a stderr tail): known secret values, bearer
    /// tokens, `key=value` pairs with a secret-ish key, URLs and token-like
    /// words are masked; the rest is left as is.
    static func scrub(_ text: String, known: [String] = []) -> String {
        var out = text
        for secret in known.filter(isKnown).sorted(by: { $0.count > $1.count }) {
            out = out.replacingOccurrences(of: secret, with: dots)
        }
        out = replace(Pattern.authScheme, in: out) { match in
            let word = match.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
            return word + " " + dots
        }
        out = replace(Pattern.secretPair, in: out) { match in
            guard let range = match.range(of: #"["']?\s*[:=]\s*["']?"#, options: .regularExpression) else { return dots }
            return String(match[..<range.upperBound]) + dots
        }
        out = replace(Pattern.url, in: out) { url($0) }
        out = replace(Pattern.tokenLike, in: out) { looksLikeToken($0) ? dots : $0 }
        return out
    }

    /// Values from a config's env and headers that must never appear anywhere.
    /// Short or obviously harmless values (flags, numbers, paths, plain URLs)
    /// are left out so masking them doesn't blank half a command line.
    static func knownSecrets(env: [String: String], headers: [String: String]) -> [String] {
        var values: [String] = []
        for (name, value) in env {
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            guard isKnown(trimmed) else { continue }
            if isSecretName(name) || looksLikeToken(trimmed)
                || !(trimmed.hasPrefix("/") || trimmed.hasPrefix("~") || trimmed.contains("://")) {
                values.append(trimmed)
            }
        }
        for value in headers.values {
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            if isKnown(trimmed) { values.append(trimmed) }
            // "Bearer abc…": the token alone can turn up elsewhere too.
            if let token = trimmed.split(separator: " ").last.map(String.init), token != trimmed, isKnown(token) {
                values.append(token)
            }
        }
        return values
    }

    /// Long enough and not a plain word mcpock would otherwise blank everywhere.
    private static func isKnown(_ value: String) -> Bool {
        guard value.count >= 6 else { return false }
        let lower = value.lowercased()
        return !["true", "false", "production", "development"].contains(lower) && Double(value) == nil
    }

    /// `scrub`'s patterns, compiled once: it runs for every group and source
    /// on each status write, and compiling four expressions per call was pure
    /// waste (review, 2026-09-26). Literal patterns, so the `try!` can't fail.
    private enum Pattern {
        static let authScheme = try! NSRegularExpression(pattern: #"(?i)\b(bearer|basic|token)\s+[A-Za-z0-9._~+/=\-]{6,}"#)
        static let secretPair = try! NSRegularExpression(
            pattern: #"(?i)\b([A-Za-z_\-]*(?:key|token|secret|password|passwd|pwd|auth|credential)[A-Za-z_\-]*)(["']?\s*[:=]\s*["']?)([^\s"'&,;]{3,})"#)
        static let url = try! NSRegularExpression(pattern: #"[A-Za-z][A-Za-z0-9+.\-]*://[^\s"'<>]+"#)
        static let tokenLike = try! NSRegularExpression(pattern: #"[A-Za-z0-9_\-+=.]{16,}"#)
    }

    private static func replace(_ regex: NSRegularExpression, in text: String, _ transform: (String) -> String) -> String {
        let ns = text as NSString
        var result = ""
        var last = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            result += transform(ns.substring(with: match.range))
            last = match.range.location + match.range.length
        }
        result += ns.substring(from: last)
        return result
    }
}
