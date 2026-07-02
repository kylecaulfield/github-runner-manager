import Foundation
import os

/// Lightweight logging wrapper around `os.Logger` plus a secret-redaction helper.
///
/// SECURITY: This is the single chokepoint for surfacing command lines / strings that might
/// contain a PAT or a registration/remove token. `redact(_:)` must be applied to ANY command
/// string before it is logged, stored in an `AppError`, or shown to the user. We never persist
/// or log secrets — the PAT lives only in the Keychain and tokens are transient.
enum Log {
    private static let logger = Logger(subsystem: "com.github.runnermanager", category: "app")

    static func info(_ msg: String) {
        // Always redact defensively: callers sometimes pass interpolated command strings.
        logger.info("\(redact(msg), privacy: .public)")
    }

    static func error(_ msg: String) {
        logger.error("\(redact(msg), privacy: .public)")
    }

    /// Replacement marker substituted in place of any detected secret.
    private static let mask = "***REDACTED***"

    /// Pre-compiled redaction rules, applied in order. Each pattern uses a capture group ($1)
    /// for the text that should be PRESERVED (the flag/prefix); the secret itself is replaced.
    ///
    /// We cover:
    ///  - `--token <value>`            (config.sh style, space-separated)
    ///  - `--token=<value>`            (equals form)
    ///  - `token <value>`             (config.cmd / generic "token " prefix)
    ///  - `Authorization: Bearer <v>`  (HTTP header echoes)
    ///  - `Authorization: token <v>`   (legacy header form)
    ///  - `ghp_…`                      (classic PAT prefix)
    ///  - `github_pat_…`               (fine-grained PAT prefix)
    ///  - bare 40-hex                  (GitHub registration/remove tokens are often hex-ish; 40-hex catches legacy tokens/SHAs)
    private static let rules: [(regex: NSRegularExpression, template: String)] = {
        // NOTE: NSRegularExpression templates use $1 for the first capture group. We escape the
        // mask isn't needed (it contains no $ or \), but we still build templates carefully so the
        // preserved prefix is re-emitted verbatim and the secret is dropped.
        let specs: [(pattern: String, template: String, options: NSRegularExpression.Options)] = [
            // --token VALUE  (also handles --token=VALUE because '=' or whitespace separates).
            // Capture the flag + separator; the value (quoted or not) is the secret.
            (#"(--token[=\s]+)["']?[^\s"']+["']?"#, "$1\(mask)", []),
            // Authorization: Bearer VALUE  /  Authorization: token VALUE
            (#"(Authorization:\s*(?:Bearer|token)\s+)\S+"#, "$1\(mask)", [.caseInsensitive]),
            // Generic "token VALUE" (e.g. config.cmd shows `--token X`, but also bare `token X`).
            // Require a word boundary so we don't clobber words ending in "token".
            (#"(\btoken[=\s]+)["']?[^\s"']+["']?"#, "$1\(mask)", [.caseInsensitive]),
            // Fine-grained PAT: github_pat_ followed by allowed chars. Check BEFORE ghp_ ordering is
            // irrelevant since prefixes differ, but list explicitly for clarity.
            (#"github_pat_[A-Za-z0-9_]+"#, mask, []),
            // Classic PAT: ghp_ / gho_ / ghu_ / ghs_ / ghr_ prefixes all share the same shape.
            (#"gh[poustr]_[A-Za-z0-9]+"#, mask, []),
            // Bare 40-char hex (legacy registration tokens / SHAs that may carry sensitive context).
            (#"\b[0-9a-fA-F]{40}\b"#, mask, [])
        ]
        return specs.compactMap { spec in
            // Force-unwrap is acceptable here only because the patterns are compile-time constants
            // and verified to be valid; if one were malformed we'd want to know at first use.
            guard let re = try? NSRegularExpression(pattern: spec.pattern, options: spec.options) else {
                // ASSUMPTION: a malformed constant regex should never ship; skip it rather than crash.
                return nil
            }
            return (re, spec.template)
        }
    }()

    /// Redact secrets from a command/string before logging or surfacing to the user.
    /// Applies each rule in sequence. Idempotent on already-redacted input.
    static func redact(_ s: String) -> String {
        guard !s.isEmpty else { return s }
        var result = s
        for rule in rules {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = rule.regex.stringByReplacingMatches(
                in: result,
                options: [],
                range: range,
                withTemplate: rule.template
            )
        }
        return result
    }
}
