import Foundation

/// The runtime status of a single self-hosted runner's launchd service, as derived
/// from `svc.sh status` (or a `launchctl list <label>` fallback).
enum RunnerStatus: Equatable {
    /// The service is loaded and running. `pid` is the launchd-reported PID when known
    /// (nil when the row reports '-', i.e. loaded but not currently running a process).
    case running(pid: Int?)
    /// The service is installed but not running.
    case stopped
    /// No launchd service is installed for this runner (svc.sh reports "not installed").
    case notInstalled
    /// Status could not be determined.
    case unknown
    /// A hard failure occurred while querying status; associated string is the detail.
    case error(String)

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    var shortLabel: String {
        switch self {
        case .running: return "Running"
        case .stopped: return "Stopped"
        case .notInstalled: return "Not installed"
        case .unknown: return "Unknown"
        case .error: return "Error"
        }
    }

    /// Coarse severity used to drive icon/color choices in the UI.
    enum Severity { case ok, warn, bad, neutral }

    var severity: Severity {
        switch self {
        case .running: return .ok
        case .stopped: return .warn
        case .notInstalled: return .neutral
        case .unknown: return .neutral
        case .error: return .bad
        }
    }
}
