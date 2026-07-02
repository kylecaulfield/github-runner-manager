import Foundation
import Security // for SecCopyErrorMessageString / OSStatus used by the .keychain case

/// The single error type surfaced throughout RunnerManager.
///
/// Every fallible operation (Process exec, network, filesystem, Keychain) maps its
/// failure into one of these cases so the UI can present a consistent, human-readable
/// message. Commands embedded in `.process` are always passed through `Log.redact`
/// before being stored so we never surface a token to the user or the logs.
enum AppError: LocalizedError, Identifiable {
    /// A shelled-out command (config.sh / svc.sh / launchctl / tar) failed.
    /// `command` MUST already be redacted by the thrower.
    case process(command: String, exitCode: Int32, stderr: String)
    /// Filesystem / IO failure.
    case io(String)
    /// Failed to parse some text/JSON (e.g. svc.sh status, a pasted add-runner block).
    case parse(String)
    /// A GitHub REST call returned a non-2xx status.
    case github(status: Int, message: String)
    /// A Security framework / Keychain call failed.
    case keychain(OSStatus)
    /// An expired/invalid registration or remove token was used.
    case invalidToken(String)
    /// An operation needs an active GUI login / elevation. The associated string IS
    /// the exact guidance command for the user to run in Terminal.
    case privilege(String)
    /// A required file/resource was not found.
    case notFound(String)
    /// The operation was cancelled.
    case cancelled
    /// A catch-all with a custom message.
    case generic(String)

    var id: String { errorDescription ?? "error" }

    var errorDescription: String? {
        switch self {
        case let .process(command, exitCode, stderr):
            // Include both the failing command and the real stderr so the user can act on it.
            // Defense-in-depth: although config.sh does not echo tokens, run stderr through the
            // same redaction as the command so a stray secret in output can never reach the UI/log.
            let trimmedErr = Log.redact(stderr).trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedErr.isEmpty {
                return "Command failed (exit \(exitCode)): \(command)"
            }
            return "Command failed (exit \(exitCode)): \(command)\n\(trimmedErr)"
        case let .io(message):
            return message
        case let .parse(message):
            return message
        case let .github(status, message):
            // 401/403 almost always mean the PAT is missing scope or expired — hint at it.
            if status == 401 || status == 403 {
                return "GitHub error \(status): \(message) (check your PAT and that it has Administration permission)"
            }
            return "GitHub error \(status): \(message)"
        case let .keychain(osStatus):
            // SecCopyErrorMessageString gives a localized Keychain error string when available.
            if let message = SecCopyErrorMessageString(osStatus, nil) as String? {
                return "Keychain error (\(osStatus)): \(message)"
            }
            return "Keychain error (\(osStatus))"
        case let .invalidToken(message):
            return message
        case let .privilege(guidance):
            // The associated string is itself the guidance the user should follow.
            return guidance
        case let .notFound(message):
            return message
        case .cancelled:
            return "The operation was cancelled."
        case let .generic(message):
            return message
        }
    }
}
