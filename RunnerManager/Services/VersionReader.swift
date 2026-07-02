import Foundation

/// Reads the locally installed runner version by exec'ing the bundled `Runner.Listener` binary.
///
/// The runner package ships NO plain-text VERSION file, so the authoritative way to learn the
/// installed version is to run `<install>/bin/Runner.Listener --version`. `--version` is a generic
/// flag that short-circuits before any configure/run logic: it prints the bare version (e.g.
/// "2.335.1") to stdout, exits 0, and performs NO network access. This makes it safe and cheap
/// to call during discovery enrichment.
enum VersionReader {
    /// Runs `<install>/bin/Runner.Listener --version` and returns the trimmed version string.
    ///
    /// Returns nil (never throws) when the binary is missing, fails to launch, exits non-zero, or
    /// prints nothing usable — callers treat an unknown version as "no update information", so a
    /// failure here must degrade gracefully rather than surface an error.
    static func installedVersion(at installPath: URL) async -> String? {
        // The version-printing entry point lives at <install>/bin/Runner.Listener.
        let listener = installPath
            .appendingPathComponent("bin")
            .appendingPathComponent("Runner.Listener")

        // If the binary isn't there (e.g. a partially-removed install), don't even try to exec.
        guard FileManager.default.isExecutableFile(atPath: listener.path) else {
            Log.info("VersionReader: Runner.Listener not found/executable at \(listener.path)")
            return nil
        }

        do {
            // Run from the install directory; Runner.Listener resolves some relative paths against cwd.
            // We do NOT throw on non-zero so any odd exit just yields nil below.
            let result = try await ProcessRunner.run(
                executable: listener,
                arguments: ["--version"],
                currentDirectory: installPath,
                throwsOnNonZero: false
            )

            // A non-zero exit means we cannot trust the output as a version. Return nil rather than
            // risk showing an stderr diagnostic as the version (which would falsely trip updateAvailable).
            guard result.succeeded else {
                Log.info("VersionReader: Runner.Listener --version exited non-zero at \(installPath.path)")
                return nil
            }

            // The version is printed ONLY to stdout. We deliberately do NOT fall back to stderr:
            // an stderr diagnostic is never a version string, and an empty stdout yields nil below.
            let source = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)

            // Defensive: take the first non-empty line in case the binary emits extra diagnostics.
            guard let line = source
                .split(whereSeparator: { $0.isNewline })
                .map({ $0.trimmingCharacters(in: .whitespaces) })
                .first(where: { !$0.isEmpty })
            else {
                return nil
            }

            // Normalize away any stray leading 'v' or whitespace to match release-tag comparisons.
            let normalized = Version.normalize(line)
            return normalized.isEmpty ? nil : normalized
        } catch {
            // ProcessRunner can still throw on a hard launch failure; degrade to nil.
            Log.error("VersionReader: failed to read version at \(installPath.path): \(error.localizedDescription)")
            return nil
        }
    }
}
