import Foundation
import AppKit

/// A single, user-selectable log file for a runner (shown in `LogTailView`'s picker).
///
/// `id` is the file's path so SwiftUI selection is stable across refreshes; `title` is the
/// short, human-facing label (e.g. "Runner log", "Worker log", "launchd stdout").
struct LogSource: Identifiable, Hashable {
    let id: String
    let title: String
    let url: URL
}

/// Reads runner log files for display and reveals them in Finder.
///
/// Pure filesystem access (no Process, no network) except `revealInFinder`, which touches
/// AppKit on the main actor. The runner writes timestamped diagnostic logs into its
/// `_diag` directory (`Runner_<timestamp>.log`, `Worker_<timestamp>.log`), and the launchd
/// LaunchAgent writes plain stdout/stderr under `~/Library/Logs/<serviceLabel>/`.
enum LogReader {
    /// Hard cap on how many bytes we read from the end of a file when tailing.
    /// 256 KB is plenty for "last N lines" of a chatty runner log while keeping memory bounded
    /// and avoiding reading multi-megabyte log files in full.
    private static let maxTailBytes = 256 * 1024

    /// Candidate logs for a runner, in priority order:
    ///  1. newest `_diag/Runner_*.log`   2. newest `_diag/Worker_*.log`
    ///  3. launchd stdout (`~/Library/Logs/<label>/stdout.log`)   4. launchd stderr (`.../stderr.log`)
    ///
    /// Only sources whose file currently exists on disk are returned, so the picker never offers
    /// a dead file. The runner rotates `_diag` logs per session/job, so we always surface the
    /// newest one by modification date rather than a fixed name.
    static func logSources(for runner: Runner) -> [LogSource] {
        var sources: [LogSource] = []

        // 1. Newest Runner_*.log in _diag (the listener/agent session log).
        if let runnerLog = newestFile(in: runner.diagDirectory, matching: "Runner_", ext: "log") {
            sources.append(LogSource(id: runnerLog.path, title: "Runner log", url: runnerLog))
        }

        // 2. Newest Worker_*.log in _diag (the per-job worker log; present only after a job ran).
        if let workerLog = newestFile(in: runner.diagDirectory, matching: "Worker_", ext: "log") {
            sources.append(LogSource(id: workerLog.path, title: "Worker log", url: workerLog))
        }

        // 3. launchd stdout — fixed path written by the LaunchAgent (absolute, NOT in the install dir).
        if let stdout = runner.launchdStdoutPath, fileExists(stdout) {
            sources.append(LogSource(id: stdout.path, title: "launchd stdout", url: stdout))
        }

        // 4. launchd stderr — same location; only surfaced when the file actually exists.
        if let stderr = runner.launchdStderrPath, fileExists(stderr) {
            sources.append(LogSource(id: stderr.path, title: "launchd stderr", url: stderr))
        }

        return sources
    }

    /// Read the last `lines` lines of `url` efficiently, reading only the trailing bytes.
    ///
    /// We seek to `max(0, fileSize - maxTailBytes)` and read forward to EOF, so even a huge log
    /// costs at most `maxTailBytes`. If we started mid-file (i.e. the file is larger than the cap)
    /// we drop the first, possibly-partial line so the output begins on a clean line boundary.
    /// Never throws; returns "" on any IO error or an empty file.
    static func tail(_ url: URL, lines: Int) -> String {
        // ASSUMPTION: a non-positive line count means "no lines requested" -> empty string.
        guard lines > 0 else { return "" }

        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }

        // Determine file size by seeking to the end.
        let fileSize: UInt64
        do {
            fileSize = try handle.seekToEnd()
        } catch {
            return ""
        }
        if fileSize == 0 { return "" }

        // Read at most `maxTailBytes` from the end of the file.
        let bytesToRead = UInt64(min(UInt64(maxTailBytes), fileSize))
        let startOffset = fileSize - bytesToRead
        let startedMidFile = startOffset > 0

        do {
            try handle.seek(toOffset: startOffset)
        } catch {
            return ""
        }

        guard let data = try? handle.readToEnd(), !data.isEmpty else { return "" }

        // Decode leniently: runner logs are UTF-8, but if we sliced through a multibyte sequence
        // at the cap boundary, `String(decoding:as:)` substitutes the replacement char rather
        // than failing, which is acceptable for a log preview.
        var text = String(decoding: data, as: UTF8.self)

        // If we began mid-file, the first line is probably truncated — drop it to avoid showing
        // a partial line at the top of the tail.
        if startedMidFile, let firstNewline = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: firstNewline)...])
        }

        // Split into lines and keep only the last `lines`. Splitting on "\n" and trimming a single
        // trailing newline avoids an empty final element while preserving interior blank lines.
        if text.hasSuffix("\n") {
            text.removeLast()
        }
        if text.isEmpty { return "" }

        let allLines = text.components(separatedBy: "\n")
        let tailLines = allLines.suffix(lines)
        return tailLines.joined(separator: "\n")
    }

    /// Reveal a file (or, if it is missing, its enclosing folder) in Finder.
    ///
    /// `NSWorkspace.activateFileViewerSelecting` opens Finder with the item selected. If the
    /// file itself does not exist (e.g. a `_diag` log that hasn't been written yet) we fall back
    /// to selecting/opening the parent directory so the user still gets somewhere useful.
    @MainActor
    static func revealInFinder(_ url: URL) {
        if fileExists(url) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            // Fall back to the containing directory.
            let parent = url.deletingLastPathComponent()
            if fileExists(parent) {
                NSWorkspace.shared.activateFileViewerSelecting([parent])
            } else {
                // Last resort: just ask Finder to open the parent path (no selection).
                NSWorkspace.shared.open(parent)
            }
        }
    }

    /// The newest file in `directory` whose name starts with `prefix` and ends with `.ext`,
    /// chosen by file modification date. Returns nil if `directory` is missing or has no match.
    ///
    /// Used to pick the current `Runner_*.log` / `Worker_*.log`, which the runner names with a
    /// timestamp per session and never reuses.
    static func newestFile(in directory: URL, matching prefix: String, ext: String) -> URL? {
        let fm = FileManager.default

        // Pull modification dates in the same enumeration to avoid a second stat per candidate.
        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        // Normalize the extension match: accept "log" or ".log".
        let suffix = ext.hasPrefix(".") ? ext : "." + ext

        var newestURL: URL?
        var newestDate = Date.distantPast

        for entry in entries {
            let name = entry.lastPathComponent
            guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { continue }

            let values = try? entry.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            // Skip anything that isn't a regular file (defensive; logs are plain files).
            if values?.isRegularFile == false { continue }

            // Fall back to distantPast when the modification date is unavailable so a dated file
            // always wins over an undatable one.
            let modDate = values?.contentModificationDate ?? .distantPast
            // Pick a strictly-newer file; on an exact date tie, break deterministically by filename
            // (the runner names these files with a lexical timestamp, so the greater name is newer).
            // The `?? true` also handles the very first matching entry (newestURL == nil).
            let isNewer: Bool
            if modDate != newestDate {
                isNewer = modDate > newestDate
            } else {
                isNewer = newestURL.map { entry.lastPathComponent > $0.lastPathComponent } ?? true
            }
            if isNewer {
                newestDate = modDate
                newestURL = entry
            }
        }

        return newestURL
    }

    // MARK: - Private helpers

    /// True iff a file or directory exists at `url`.
    private static func fileExists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }
}
