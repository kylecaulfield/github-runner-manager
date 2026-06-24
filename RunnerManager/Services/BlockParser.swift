import Foundation

/// The fields we extract from the "Add new self-hosted runner" block that GitHub shows
/// in the repository/organization/enterprise Settings UI. The `--token` here is a short-lived
/// *registration* token (not a PAT); it is transient and must never be persisted or logged.
struct ParsedRunnerBlock: Equatable {
    /// The raw `--url` value pasted by the user (e.g. https://github.com/owner/repo).
    let url: String
    /// The scope classified from `url`.
    let scope: RunnerScope
    /// The registration token from `--token` (quoted or `=`-joined forms accepted).
    let token: String
    /// The runner version parsed from a download URL in the block, if one is present
    /// (the block GitHub shows for macOS/Windows includes a `curl`/`Invoke-WebRequest`
    /// line that downloads `actions-runner-<os>-<arch>-<VERSION>.{tar.gz|zip}`).
    let version: String?
}

/// Parses the multi-line shell block that GitHub presents on the "Add new self-hosted runner"
/// page. The same block exists for macOS/Linux (`config.sh` + `curl`) and Windows
/// (`config.cmd` + `Invoke-WebRequest`); we support both syntaxes by matching the common
/// `--url` / `--token` flags and the download asset name. Nothing here touches the network
/// or filesystem — it is a pure text parse and is safe to call from any thread.
enum BlockParser {
    /// Parse the pasted block and extract `--url`, `--token`, and (best-effort) the version.
    ///
    /// Throws `AppError.parse` if either the URL or the token is missing — those are the two
    /// fields required to register a runner; version is optional (we fall back to the latest
    /// release when it cannot be determined).
    static func parse(_ text: String) throws -> ParsedRunnerBlock {
        // --url <url> — capture the http(s) URL. The value may be wrapped in single or double
        // quotes (GitHub does not quote it, but users sometimes do). We stop at the first
        // whitespace or closing quote. NOTE: GitHub only ever emits https URLs here.
        // ASSUMPTION: only https GitHub URLs appear in the block; we anchor on "https://".
        let urlPattern = #"--url[\s=]+["']?(https://[^\s"']+)"#

        // --token <token> — registration tokens are alphanumeric plus underscores. Accept both
        // the space-separated (`--token ABC`) and `=`-joined (`--token=ABC`) forms, with optional
        // surrounding quotes (config.cmd on Windows often quotes the value: --token "ABC").
        let tokenPattern = #"--token[\s=]+["']?([A-Za-z0-9_]+)"#

        // Version from the download asset name. The block downloads e.g.
        //   actions-runner-osx-arm64-2.335.1.tar.gz   (macOS)
        //   actions-runner-win-x64-2.335.1.zip        (Windows)
        // We capture the dotted version that precedes the .tar.gz / .zip extension.
        let versionPattern = #"actions-runner-[a-z0-9]+-[a-z0-9]+-([0-9]+\.[0-9]+\.[0-9]+)\.(?:tar\.gz|zip)"#

        guard let url = firstCaptureGroup(in: text, pattern: urlPattern) else {
            throw AppError.parse("Couldn't find a runner URL (--url) in the pasted block.")
        }
        guard let token = firstCaptureGroup(in: text, pattern: tokenPattern) else {
            throw AppError.parse("Couldn't find a registration token (--token) in the pasted block.")
        }

        // Version is optional — a partial paste (just the config line) is still usable.
        let version = firstCaptureGroup(in: text, pattern: versionPattern)

        let scope = RunnerScope.parse(from: url)
        return ParsedRunnerBlock(url: url, scope: scope, token: token, version: version)
    }

    /// Returns the first capture group (group 1) of the first match of `pattern` in `text`,
    /// or nil if the pattern doesn't compile or doesn't match. Case-insensitive so the
    /// Windows `Invoke-WebRequest` line (and any odd casing) still matches the asset name.
    private static func firstCaptureGroup(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges > 1 else {
            return nil
        }
        // Group 1 holds the captured value; convert the NSRange back to a Swift String range.
        let captureRange = match.range(at: 1)
        guard captureRange.location != NSNotFound,
              let swiftRange = Range(captureRange, in: text) else {
            return nil
        }
        return String(text[swiftRange])
    }
}
