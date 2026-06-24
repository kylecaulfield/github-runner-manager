import Foundation

/// Drives a runner's launchd LaunchAgent through the runner's own `svc.sh` wrapper.
///
/// On macOS the runner installs as a per-user LaunchAgent (`~/Library/LaunchAgents/<label>.plist`)
/// and ships a `svc.sh` script that wraps the legacy `launchctl load -w` / `launchctl unload`
/// flow plus a `status` subcommand. We never run anything as root: `svc.sh` itself refuses to run
/// under sudo (`if [ $user_id -eq 0 ]; then echo "Must not run with sudo"; exit 1; fi`), and the
/// LaunchAgent only runs while there is an active GUI login session for the user. Those two facts
/// drive the error mapping below.
enum ServiceController {

    // MARK: - Public service operations

    /// Query the live service status by running `./svc.sh status` from the install directory and
    /// parsing its output. Falls back to `launchctl list <label>` if `svc.sh` is absent (e.g. a
    /// partially-removed install). Never throws — a hard failure is reported as `.error(...)` so the
    /// UI can keep rendering the rest of the runner list.
    static func status(for runner: Runner) async -> RunnerStatus {
        let svc = svcPath(for: runner.installPath)

        if FileManager.default.isExecutableFile(atPath: svc.path) {
            do {
                // svc.sh status exits 0 in the normal "installed" cases; don't throw on non-zero.
                let result = try await ProcessRunner.runScript(
                    svc, ["status"],
                    currentDirectory: runner.installPath,
                    throwsOnNonZero: false
                )
                // svc.sh writes the human-readable status to stdout; combine with stderr defensively.
                let combined = result.stdout + "\n" + result.stderr
                let parsed = parseStatus(combined)
                // If svc.sh produced nothing we can interpret, fall back to launchctl.
                if case .unknown = parsed, let label = runner.serviceLabel, !label.isEmpty {
                    return await launchctlStatus(label: label)
                }
                return parsed
            } catch {
                Log.error("ServiceController.status: svc.sh failed at \(runner.installPath.path): \(error.localizedDescription)")
                // Fall through to launchctl as a last resort before reporting an error.
                if let label = runner.serviceLabel, !label.isEmpty {
                    return await launchctlStatus(label: label)
                }
                return .error(error.localizedDescription)
            }
        }

        // No svc.sh present — use the launchctl fallback if we know the service label.
        if let label = runner.serviceLabel, !label.isEmpty {
            return await launchctlStatus(label: label)
        }
        return .notInstalled
    }

    /// `./svc.sh start` — `launchctl load -w "${PLIST_PATH}"`. The service then runs at load and
    /// (via `RunAtLoad`) keeps running until unloaded.
    static func start(_ runner: Runner) async throws {
        try await runSvc(["start"], at: runner.installPath)
    }

    /// `./svc.sh stop` — `launchctl unload "${PLIST_PATH}"`.
    static func stop(_ runner: Runner) async throws {
        try await runSvc(["stop"], at: runner.installPath)
    }

    /// Restart = stop then start. We deliberately run them as two discrete svc.sh calls (matching
    /// what a user would do by hand) so each step's error is mapped/surfaced precisely.
    static func restart(_ runner: Runner) async throws {
        try await stop(runner)
        try await start(runner)
    }

    /// `./svc.sh install` — creates `~/Library/LaunchAgents`, fails if the plist already exists,
    /// copies `bin/runsvc.sh` into place, and writes the `.service` file. It does NOT start the
    /// service (start is a separate step).
    static func install(at installPath: URL) async throws {
        try await runSvc(["install"], at: installPath)
    }

    /// `./svc.sh uninstall` — unloads the agent, then removes the plist and the `.service` file.
    static func uninstall(at installPath: URL) async throws {
        try await runSvc(["uninstall"], at: installPath)
    }

    // MARK: - Pure parsing (testable)

    /// Parse the textual output of `./svc.sh status` into a `RunnerStatus`.
    ///
    /// Rules (per the darwin svc.sh template, RESEARCH.md):
    ///  - Output containing "not installed"  → `.notInstalled`.
    ///  - Otherwise, output containing "Started:" → `.running`. The launchctl row that follows is
    ///    `"<PID> <exit> <label>"`; we read the first numeric token as the PID, mapping a literal
    ///    '-' (loaded but not currently running a process) to a nil PID.
    ///  - Otherwise, output containing "Stopped" → `.stopped`.
    ///  - Anything else → `.unknown`.
    static func parseStatus(_ output: String) -> RunnerStatus {
        let lower = output.lowercased()

        // "not installed" is the unambiguous signal that no plist/service exists.
        if lower.contains("not installed") {
            return .notInstalled
        }

        // "Started:" precedes a launchctl row carrying the PID. Match case-insensitively for safety.
        if lower.contains("started:") {
            return .running(pid: extractStartedPID(from: output))
        }

        // "Stopped" means the plist exists but the agent is unloaded / not running.
        if lower.contains("stopped") {
            return .stopped
        }

        return .unknown
    }

    // MARK: - svc.sh execution + error mapping

    /// Run a single `svc.sh <args>` invocation, mapping privilege/session failures to
    /// `AppError.privilege` with exact-command guidance and everything else to `AppError.process`.
    private static func runSvc(_ arguments: [String], at installPath: URL) async throws {
        let svc = svcPath(for: installPath)

        guard FileManager.default.isExecutableFile(atPath: svc.path) else {
            // No svc.sh to drive the service — this is a structural problem, not a transient one.
            throw AppError.notFound("svc.sh not found or not executable at \(svc.path)")
        }

        // We intentionally pass throwsOnNonZero:false so we can inspect stdout+stderr ourselves and
        // produce a privilege-aware error rather than a generic process failure.
        let result = try await ProcessRunner.runScript(
            svc, arguments,
            currentDirectory: installPath,
            throwsOnNonZero: false
        )

        guard !result.succeeded else { return }

        // Combine streams: svc.sh's failed() writes to stderr, but some messages land on stdout.
        let combined = (result.stdout + "\n" + result.stderr)
        let lower = combined.lowercased()

        // "Must not run with sudo": svc.sh refuses to run as root. We never invoke sudo ourselves,
        // so seeing this means the user's environment is running the app/elevated unexpectedly.
        // Guide them to run svc.sh directly, without sudo, from the install dir.
        if lower.contains("must not run with sudo") {
            throw AppError.privilege(
                "Do not run as root. Run this in Terminal: cd \(installPath.path) && ./svc.sh \(arguments.joined(separator: " "))"
            )
        }

        // launchctl load/unload failures are frequently session/login-domain related: a user-domain
        // LaunchAgent needs an active GUI login. svc.sh surfaces these as `Failed: ...`. When the
        // failure looks privilege/session-related, prefer privilege guidance over a raw process error.
        if isLaunchctlSessionFailure(lower) {
            throw AppError.privilege(
                "Some launchd operations need an active GUI login. Try in Terminal: cd \(installPath.path) && ./svc.sh \(arguments.joined(separator: " "))"
            )
        }

        // Otherwise surface the real stderr (redaction handled inside AppError via the command field).
        let stderr = result.stderr.isEmpty ? result.stdout : result.stderr
        throw AppError.process(
            command: Log.redact(result.commandLine),
            exitCode: result.exitCode,
            stderr: stderr
        )
    }

    /// Heuristic for "this looks like a launchd privilege / session failure" so we can redirect the
    /// user to Terminal with an active login session. We require a `Failed`/load/unload signal AND a
    /// domain/session/permission hint to avoid misclassifying unrelated `Failed:` messages.
    private static func isLaunchctlSessionFailure(_ lower: String) -> Bool {
        let mentionsLoadUnload =
            lower.contains("load") ||
            lower.contains("unload") ||
            lower.contains("bootstrap") ||
            lower.contains("bootout") ||
            lower.contains("failed")

        guard mentionsLoadUnload else { return false }

        // Domain/session/permission hints emitted by launchctl when there's no active GUI session
        // or insufficient privileges to operate in the user's launchd domain.
        let sessionHints = [
            "domain",                 // "Could not find domain for ..."
            "gui",                    // gui/<uid> domain references
            "no such process",        // unload when nothing is loaded in this session
            "operation not permitted",
            "permission denied",
            "not permitted",
            "input/output error",     // common when the user domain is unavailable
            "could not find",
            "bootstrap"
        ]
        return sessionHints.contains { lower.contains($0) }
    }

    // MARK: - launchctl fallback

    /// Fallback status via `launchctl list <label>`. Exit 0 with a property-list-ish dump means the
    /// service is loaded; we read `"PID" = <n>` to distinguish running (numeric PID present) from
    /// loaded-but-not-running. A non-zero exit (label not found) means the service isn't loaded.
    private static func launchctlStatus(label: String) async -> RunnerStatus {
        let launchctl = URL(fileURLWithPath: "/bin/launchctl")
        do {
            let result = try await ProcessRunner.run(
                executable: launchctl,
                arguments: ["list", label],
                throwsOnNonZero: false
            )
            // `launchctl list <label>` exits non-zero when the label isn't loaded in this domain.
            guard result.succeeded else {
                // Not loaded. We can't tell "not installed" from "installed but stopped" purely from
                // launchctl, but for a known label the service exists, so report Stopped.
                return .stopped
            }
            // Parse the "PID" = <n>; line from the plist-ish dump.
            if let pid = extractLaunchctlListPID(from: result.stdout) {
                return .running(pid: pid)
            }
            // Loaded but no PID key (or PID = 0): treat as running with unknown PID.
            return .running(pid: nil)
        } catch {
            return .error(error.localizedDescription)
        }
    }

    // MARK: - PID extraction helpers

    /// Extract the PID from the launchctl row that follows the "Started:" marker in `svc.sh status`.
    ///
    /// svc.sh prints (roughly):
    ///   Started:
    ///   <PID>	<exit-status>	<label>
    /// where <PID> is numeric while running, or '-' when loaded but not currently running.
    private static func extractStartedPID(from output: String) -> Int? {
        let lines = output.components(separatedBy: .newlines)
        // Find the "Started:" line, then look at subsequent non-empty lines for the launchctl row.
        guard let startedIndex = lines.firstIndex(where: { $0.lowercased().contains("started:") }) else {
            return nil
        }
        for line in lines[(startedIndex + 1)...] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            // The first whitespace-separated token is the PID column.
            guard let firstToken = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" }).first else {
                continue
            }
            let token = String(firstToken)
            // '-' means loaded but not running → nil PID.
            if token == "-" { return nil }
            return Int(token)
        }
        return nil
    }

    /// Extract the numeric PID from a `launchctl list <label>` dump, which contains a line like
    /// `\t"PID" = 12345;`. A `0` or missing value means loaded-but-not-running → nil.
    private static func extractLaunchctlListPID(from output: String) -> Int? {
        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("\"PID\"") else { continue }
            // Form: "PID" = 12345;
            guard let equalsIndex = trimmed.firstIndex(of: "=") else { return nil }
            let valuePart = trimmed[trimmed.index(after: equalsIndex)...]
                .trimmingCharacters(in: CharacterSet(charactersIn: " ;\t"))
            if let pid = Int(valuePart), pid > 0 { return pid }
            return nil
        }
        return nil
    }

    // MARK: - Path helper

    /// The `svc.sh` path for a given install directory.
    private static func svcPath(for installPath: URL) -> URL {
        installPath.appendingPathComponent("svc.sh")
    }
}
