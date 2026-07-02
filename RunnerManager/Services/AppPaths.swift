import Foundation

/// Centralized filesystem locations used by the app.
///
/// All directories are created lazily on access where it makes sense (Application Support,
/// download cache). Tilde expansion is anchored on the current user's real home directory
/// (via `FileManager.homeDirectoryForCurrentUser`) rather than `NSHomeDirectory()` so it stays
/// correct even though App Sandbox is OFF (no container redirection).
enum AppPaths {
    /// The app's name component used under Application Support.
    private static let appFolderName = "RunnerManager"

    /// `~/Library/Application Support/RunnerManager`, created on access.
    static var appSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            // Fallback to ~/Library/Application Support if the search returns nothing (shouldn't happen).
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        let dir = base.appendingPathComponent(appFolderName, isDirectory: true)
        // Best-effort creation; failures here surface later when callers try to write.
        try? ensureDirectory(dir)
        return dir
    }

    /// `~/Library/Application Support/RunnerManager/Downloads`, created on access.
    /// Used to cache runner tarballs so repeat installs/updates can reuse a download.
    static var downloadCache: URL {
        let dir = appSupport.appendingPathComponent("Downloads", isDirectory: true)
        try? ensureDirectory(dir)
        return dir
    }

    /// Create `url` (and intermediate directories) if it does not already exist.
    /// Throws `AppError.io` with a human-readable reason on failure.
    static func ensureDirectory(_ url: URL) throws {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: url.path, isDirectory: &isDir) {
            if isDir.boolValue { return }
            throw AppError.io("Expected a directory but found a file at \(url.path)")
        }
        do {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw AppError.io("Could not create directory at \(url.path): \(error.localizedDescription)")
        }
    }

    /// Expand a leading `~` (or `~/`) to the current user's home directory and return a file URL.
    /// A non-tilde path is returned as-is (standardized) as a file URL.
    static func expandTilde(_ path: String) -> URL {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let home = FileManager.default.homeDirectoryForCurrentUser

        if trimmed == "~" {
            return home
        }
        if trimmed.hasPrefix("~/") {
            // Drop the leading "~/" and append the remainder relative to home.
            let remainder = String(trimmed.dropFirst(2))
            return home.appendingPathComponent(remainder).standardizedFileURL
        }
        // ASSUMPTION: "~user" forms (other users' homes) are out of scope per RESEARCH.md;
        // fall back to NSString tilde expansion which handles them best-effort, else use as-is.
        if trimmed.hasPrefix("~") {
            let expanded = (trimmed as NSString).expandingTildeInPath
            return URL(fileURLWithPath: expanded).standardizedFileURL
        }
        return URL(fileURLWithPath: trimmed).standardizedFileURL
    }

    /// Default parent directory for new runner installs: `~/actions-runners`.
    static var defaultInstallRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("actions-runners", isDirectory: true)
    }
}
