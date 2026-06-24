import Foundation
import Combine // ObservableObject / @Published live in Combine (Foundation does not re-export them)

/// User-facing, non-secret application settings, backed by `UserDefaults.standard`.
///
/// SECURITY: This object NEVER stores secrets. The PAT and any registration/remove
/// tokens live only in the Keychain (see `KeychainStore`). Only benign configuration
/// (search paths, polling interval, defaults) is persisted here.
///
/// Each `@Published` property persists via `didSet` so changes made in the UI are
/// written through immediately. Values are loaded from `UserDefaults` (or sensible
/// defaults) in `init()`, and numeric values are clamped to their valid ranges.
@MainActor
final class AppSettings: ObservableObject {

    // MARK: - UserDefaults keys

    private enum Keys {
        static let searchPaths = "searchPaths"
        static let pollIntervalSeconds = "pollIntervalSeconds"
        static let defaultRunnerGroup = "defaultRunnerGroup"
        static let defaultInstallRoot = "defaultInstallRoot"
        static let maxDiscoveryDepth = "maxDiscoveryDepth"
        static let logTailLines = "logTailLines"
    }

    // MARK: - Clamp ranges (per spec)

    private static let pollIntervalRange: ClosedRange<Double> = 2.0...60.0
    private static let discoveryDepthRange: ClosedRange<Int> = 1...6

    /// Guards `didSet` persistence so that loading values in `init()` does not
    /// trigger redundant writes back to `UserDefaults`.
    private var isLoading = false

    // MARK: - Persisted properties

    /// Directories to scan for runner installs. Persisted under key "searchPaths".
    @Published var searchPaths: [String] {
        didSet { persist(searchPaths, forKey: Keys.searchPaths) }
    }

    /// Status-polling interval in seconds. Default 5, clamped to 2…60.
    @Published var pollIntervalSeconds: Double {
        didSet {
            // Clamp; only re-assign (which re-fires didSet) if clamping changed the value
            // to avoid an infinite didSet loop.
            let clamped = AppSettings.pollIntervalRange.clamping(pollIntervalSeconds)
            if clamped != pollIntervalSeconds {
                pollIntervalSeconds = clamped
                return
            }
            persist(pollIntervalSeconds, forKey: Keys.pollIntervalSeconds)
        }
    }

    /// Default runner group used when creating org/enterprise runners. Default "default".
    @Published var defaultRunnerGroup: String {
        didSet { persist(defaultRunnerGroup, forKey: Keys.defaultRunnerGroup) }
    }

    /// Default parent directory for new installs. Default "~/actions-runners".
    @Published var defaultInstallRoot: String {
        didSet { persist(defaultInstallRoot, forKey: Keys.defaultInstallRoot) }
    }

    /// Maximum directory recursion depth for discovery. Default 3, clamped to 1…6.
    @Published var maxDiscoveryDepth: Int {
        didSet {
            let clamped = AppSettings.discoveryDepthRange.clamping(maxDiscoveryDepth)
            if clamped != maxDiscoveryDepth {
                maxDiscoveryDepth = clamped
                return
            }
            persist(maxDiscoveryDepth, forKey: Keys.maxDiscoveryDepth)
        }
    }

    /// Number of trailing log lines to show in the log tail view. Default 200.
    @Published var logTailLines: Int {
        didSet { persist(logTailLines, forKey: Keys.logTailLines) }
    }

    // MARK: - Defaults

    /// Default search paths used when none have been persisted yet.
    /// ASSUMPTION: per spec we scan ~/actions-runner[s] plus the home dir (depth-limited);
    /// the user can add custom paths in Settings.
    static var defaultSearchPaths: [String] {
        ["~/actions-runner", "~/actions-runners", "~"]
    }

    // MARK: - Init

    /// Load from `UserDefaults` or fall back to defaults. Numeric values are clamped.
    init() {
        let defaults = UserDefaults.standard
        isLoading = true

        // searchPaths: use persisted non-empty array of strings, else defaults.
        if let stored = defaults.array(forKey: Keys.searchPaths) as? [String], !stored.isEmpty {
            searchPaths = stored
        } else {
            searchPaths = AppSettings.defaultSearchPaths
        }

        // pollIntervalSeconds: default 5 if unset (object(forKey:) == nil), else clamp.
        if defaults.object(forKey: Keys.pollIntervalSeconds) == nil {
            pollIntervalSeconds = 5.0
        } else {
            pollIntervalSeconds = AppSettings.pollIntervalRange.clamping(
                defaults.double(forKey: Keys.pollIntervalSeconds))
        }

        defaultRunnerGroup = defaults.string(forKey: Keys.defaultRunnerGroup) ?? "default"
        defaultInstallRoot = defaults.string(forKey: Keys.defaultInstallRoot) ?? "~/actions-runners"

        // maxDiscoveryDepth: default 3 if unset, else clamp.
        if defaults.object(forKey: Keys.maxDiscoveryDepth) == nil {
            maxDiscoveryDepth = 3
        } else {
            maxDiscoveryDepth = AppSettings.discoveryDepthRange.clamping(
                defaults.integer(forKey: Keys.maxDiscoveryDepth))
        }

        // logTailLines: default 200 if unset.
        if defaults.object(forKey: Keys.logTailLines) == nil {
            logTailLines = 200
        } else {
            logTailLines = defaults.integer(forKey: Keys.logTailLines)
        }

        isLoading = false
    }

    // MARK: - Resolved search paths

    /// Tilde-expanded, de-duplicated search paths, keeping only paths that currently
    /// exist as directories. Order of first occurrence is preserved.
    func resolvedSearchPaths() -> [URL] {
        let fileManager = FileManager.default
        var seen = Set<String>()
        var result: [URL] = []

        for raw in searchPaths {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            // Expand a leading "~" (or "~/...") to the user's home directory.
            let url = AppSettings.expandTilde(trimmed)
            // Standardize to dedupe equivalent paths (e.g. trailing slashes, "." segments).
            let standardized = url.standardizedFileURL
            let key = standardized.path

            guard !seen.contains(key) else { continue }

            // Keep only existing directories.
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: standardized.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }

            seen.insert(key)
            result.append(standardized)
        }

        return result
    }

    // MARK: - Helpers

    /// Expand a leading "~" to the current user's home directory and return a file URL.
    /// Uses `NSString.expandingTildeInPath` for "~" / "~/..." handling.
    private static func expandTilde(_ path: String) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded)
    }

    /// Persist a value, unless we're currently loading (to avoid redundant writes).
    private func persist(_ value: Any, forKey key: String) {
        guard !isLoading else { return }
        UserDefaults.standard.set(value, forKey: key)
    }
}

// MARK: - ClosedRange clamping

private extension ClosedRange {
    /// Returns `value` constrained to this range.
    func clamping(_ value: Bound) -> Bound {
        if value < lowerBound { return lowerBound }
        if value > upperBound { return upperBound }
        return value
    }
}
