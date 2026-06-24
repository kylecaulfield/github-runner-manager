import Foundation

/// The central model for a single self-hosted GitHub Actions runner installed on this Mac.
///
/// A `Runner` combines:
///  - immutable discovery-time facts read off disk (install path, parsed `.runner`,
///    derived `scope`, and the launchd service label/plist),
///  - fields enriched asynchronously after discovery (live service `status`, the locally
///    installed runner version, the latest published release version, and server-side
///    labels fetched from the GitHub API),
///  - and a handful of derived paths/computed flags used by the UI.
///
/// Identity is the install directory path, so the same install discovered twice is `==`
/// and de-duplicates in lists.
struct Runner: Identifiable, Equatable {
    // MARK: - Identity / discovery-time (immutable)

    /// Stable identity. Equals `installPath.path` so a runner is uniquely keyed by where
    /// it lives on disk (two discoveries of the same install collapse to one).
    let id: String

    /// The runner install directory (the folder containing `config.sh`, `svc.sh`, `.runner`).
    let installPath: URL

    /// Human-facing name: the configured agent name from `.runner` when available,
    /// otherwise the install directory's last path component.
    let name: String

    /// Parsed `.runner` JSON, or nil if the file is missing/unreadable.
    let config: RunnerConfig?

    /// Where this runner is registered, parsed from `config?.gitHubUrl`.
    let scope: RunnerScope

    /// The launchd service label (e.g. `actions.runner.owner-repo.name`), taken from the
    /// `.service` file's plist basename when present, or constructed from scope + name.
    /// nil when no service is installed and no label could be constructed.
    let serviceLabel: String?

    /// Absolute path to the LaunchAgent plist, `~/Library/LaunchAgents/<label>.plist`.
    /// Read from the `.service` file on macOS (which contains the absolute plist path),
    /// or constructed from `serviceLabel`. nil when there is no label.
    let servicePlistPath: URL?

    // MARK: - Enriched asynchronously (mutable)

    /// Live launchd service status. Starts `.unknown`; refreshed by `ServiceController`.
    var status: RunnerStatus = .unknown

    /// The locally installed runner version (from `bin/Runner.Listener --version`),
    /// without a leading 'v'. nil until read.
    var installedVersion: String?

    /// The latest published runner release version (release `tag_name` with the 'v' stripped).
    /// nil until fetched from the GitHub releases API.
    var latestVersion: String?

    /// Runner labels. These live server-side only (NOT in `.runner`), so they are fetched
    /// from `GET …/actions/runners` and require a PAT. Empty when unknown.
    var labels: [String] = []

    // MARK: - Derived paths

    /// The runner's `_diag` directory, where `Runner_*.log`/`Worker_*.log` files are written.
    var diagDirectory: URL { installPath.appendingPathComponent("_diag") }

    /// launchd stdout log path: `~/Library/Logs/<serviceLabel>/stdout.log`.
    ///
    /// Per the svc.sh / plist template, the LaunchAgent's `StandardOutPath` is an ABSOLUTE
    /// path under `~/Library/Logs/<SVC_NAME>/` (NOT inside the install dir), where
    /// `<SVC_NAME>` is the service label. nil when there is no service label.
    var launchdStdoutPath: URL? {
        guard let label = serviceLabel, !label.isEmpty else { return nil }
        return Runner.launchdLogDirectory(for: label).appendingPathComponent("stdout.log")
    }

    /// launchd stderr log path: `~/Library/Logs/<serviceLabel>/stderr.log`. See `launchdStdoutPath`.
    var launchdStderrPath: URL? {
        guard let label = serviceLabel, !label.isEmpty else { return nil }
        return Runner.launchdLogDirectory(for: label).appendingPathComponent("stderr.log")
    }

    // MARK: - Computed

    /// Convenience accessor for the configured GitHub URL (config.sh `--url`).
    var gitHubURL: String? { config?.gitHubUrl }

    /// True iff both the installed and latest versions are known AND latest is strictly newer.
    /// Unknown versions never report an available update (avoids false "Update" badges).
    var updateAvailable: Bool {
        guard let i = installedVersion, let l = latestVersion else { return false }
        return Version.isNewer(l, than: i)
    }

    // MARK: - Helpers

    /// The `~/Library/Logs/<label>/` directory holding the launchd stdout/stderr logs for `label`.
    ///
    /// Uses `FileManager.homeDirectoryForCurrentUser` so the path resolves to the real home
    /// even when the app is not sandboxed and `~` expansion would otherwise be ambiguous.
    static func launchdLogDirectory(for label: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
            .appendingPathComponent("Logs")
            .appendingPathComponent(label)
    }
}
