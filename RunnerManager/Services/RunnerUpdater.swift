import Foundation

/// Updates a runner's binaries IN PLACE while preserving its existing registration.
///
/// The runner package tarball contains ONLY `bin/`, `externals/`, and the root scripts (config.sh,
/// svc.sh, run.sh, …) — it carries no config/credential files. So the manual-update procedure is:
///
///   1. `./svc.sh stop`
///   2. download + `tar xzf` the NEW tarball OVER the install directory. Because the tarball has no
///      config/credential entries, this leaves the registration files untouched:
///      `.runner`, `.credentials`, `.credentials_rsaparams`, `.env`, `.service`, `.path`,
///      `.credential_store*`, `.setup_info`, `.options`, and the `_work/`, `_diag/` directories.
///   3. refresh `./runsvc.sh` from the freshly-extracted `bin/runsvc.sh` (svc.sh copies it at install
///      time; an in-place update must re-copy it so the launchd-invoked wrapper matches the new bits).
///   4. `./svc.sh start`
///
/// We NEVER de-register / re-register here — that would require a fresh registration token and would
/// change the runner's server-side identity. A guard verifies `.runner` still exists after extraction
/// so we never silently start a runner whose registration was clobbered.
enum RunnerUpdater {

    /// GitHub's public REST host. Release metadata is fetched here WITHOUT the PAT.
    private static let apiBase = "https://api.github.com"

    /// Update `runner`'s binaries to `version` (or the latest release when `version` is nil).
    ///
    /// Skips entirely (no stop/start) when the runner is already at the target version.
    ///
    /// Throws:
    ///  - `AppError.io` if the install path is missing, or if `.runner` is absent AFTER extraction
    ///    (registration would have been lost — we refuse to proceed).
    ///  - `AppError.process` / `AppError.notFound` for download/extract/svc.sh failures.
    static func update(
        _ runner: Runner,
        to version: String?,
        downloadCache: URL?,
        progress: @escaping @MainActor (String) -> Void
    ) async throws {
        let installDir = runner.installPath
        let fm = FileManager.default

        // Sanity: the install directory and its registration file must exist before we touch anything.
        let runnerConfigFile = installDir.appendingPathComponent(".runner")
        guard fm.fileExists(atPath: installDir.path) else {
            throw AppError.io("Install directory not found at \(installDir.path).")
        }
        guard fm.fileExists(atPath: runnerConfigFile.path) else {
            // No registration on disk -> this isn't a configured runner; updating it makes no sense.
            throw AppError.io("This runner has no .runner registration file at \(installDir.path); refusing to update.")
        }

        // --- 1. Resolve the target release + asset. ----------------------------------------------
        await report(progress, version.map { "Resolving runner release \($0)…" }
            ?? "Resolving latest runner release…")
        let release = try await resolveRelease(version: version)
        guard let asset = release.macOSArm64Asset() else {
            throw AppError.notFound(
                "No macOS arm64 asset (actions-runner-osx-arm64-*.tar.gz) found in runner release \(release.tagName).")
        }
        let targetVersion = release.version

        // --- Skip if already at the target version. ----------------------------------------------
        // Read the installed version fresh (don't trust a possibly-stale enriched field on `runner`).
        let installed = runner.installedVersion ?? (await VersionReader.installedVersion(at: installDir))
        if let installed, Version.compare(installed, targetVersion) == .orderedSame {
            await report(progress, "Runner is already at version \(targetVersion); nothing to update.")
            return
        }

        // --- 2. Download (reuse cache) the new tarball. ------------------------------------------
        let cacheDir = downloadCache ?? AppPaths.downloadCache
        try AppPaths.ensureDirectory(cacheDir)
        let tarball = cacheDir.appendingPathComponent(asset.name)
        if isUsableCachedFile(tarball) {
            await report(progress, "Reusing cached download \(asset.name)")
        } else {
            await report(progress, "Downloading \(asset.name)…")
            // Reuse the installer's PAT-free downloader (never forwards the PAT across the redirect).
            try await RunnerInstaller.download(asset, to: tarball, progress: progress)
        }

        // --- 1. Stop the service BEFORE swapping binaries. ---------------------------------------
        // Stop first so launchd isn't executing the binaries we're about to overwrite.
        await report(progress, "Stopping runner service…")
        try await ServiceController.stop(runner)

        // --- 2. Extract the new tarball OVER the install directory. -------------------------------
        // The tarball has no config/credential entries, so this preserves the registration files.
        await report(progress, "Extracting runner package over existing install…")
        try await RunnerInstaller.extractTarball(tarball, into: installDir)

        // --- Guard: registration must still be intact after extraction. --------------------------
        guard fm.fileExists(atPath: runnerConfigFile.path) else {
            throw AppError.io(
                "Update aborted: the .runner registration file is missing after extraction at \(installDir.path). "
                + "The runner's registration may be damaged; do not start it.")
        }

        // --- 3. Refresh ./runsvc.sh from the freshly-extracted bin/runsvc.sh. ---------------------
        // svc.sh copies bin/runsvc.sh -> ./runsvc.sh (+x) at install time. An in-place update must
        // re-copy it so the launchd-invoked wrapper (ProgramArguments points at <root>/runsvc.sh)
        // matches the updated runner bits.
        try refreshRunsvc(in: installDir)

        // --- 4. Start the service again. ---------------------------------------------------------
        await report(progress, "Starting runner service…")
        try await ServiceController.start(runner)

        await report(progress, "Runner updated to version \(targetVersion).")
    }

    // MARK: - runsvc.sh refresh

    /// Copy `bin/runsvc.sh` -> `./runsvc.sh` (overwriting), preserving the executable bit.
    ///
    /// This mirrors what `svc.sh install` does. If the source isn't present (older/odd package
    /// layout) we leave the existing `./runsvc.sh` in place rather than failing the whole update.
    private static func refreshRunsvc(in installDir: URL) throws {
        let fm = FileManager.default
        let source = installDir.appendingPathComponent("bin").appendingPathComponent("runsvc.sh")
        let destination = installDir.appendingPathComponent("runsvc.sh")

        guard fm.fileExists(atPath: source.path) else {
            // ASSUMPTION: a missing bin/runsvc.sh in the new tarball is unexpected; keep the old wrapper.
            Log.info("RunnerUpdater: bin/runsvc.sh not found at \(source.path); keeping existing runsvc.sh")
            return
        }

        do {
            if fm.fileExists(atPath: destination.path) {
                try fm.removeItem(at: destination)
            }
            try fm.copyItem(at: source, to: destination)
            // Ensure the wrapper is executable; launchd execs it directly via the plist ProgramArguments.
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
        } catch {
            throw AppError.io("Failed to refresh runsvc.sh at \(destination.path): \(error.localizedDescription)")
        }
    }

    // MARK: - Release resolution

    /// Resolve the `GitHubRelease` to install: the latest release when `version` is nil, or the
    /// release tagged `v<version>` otherwise. Both reads are unauthenticated (public endpoints) so
    /// the PAT is never forwarded.
    private static func resolveRelease(version: String?) async throws -> GitHubRelease {
        guard let version, !version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return try await GitHubAPI(token: nil).latestRelease()
        }
        // Release tags carry a leading 'v' (e.g. "v2.335.1"); normalize then re-prefix.
        let tag = "v\(Version.normalize(version))"
        return try await releaseByTag(tag)
    }

    /// GET `…/repos/actions/runner/releases/tags/<tag>` (public; no PAT). Decodes a `GitHubRelease`.
    private static func releaseByTag(_ tag: String) async throws -> GitHubRelease {
        guard let url = URL(string: "\(apiBase)/repos/actions/runner/releases/tags/\(tag)") else {
            throw AppError.generic("Could not build release-by-tag URL for \(tag).")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("RunnerManager", forHTTPHeaderField: "User-Agent")
        // No Authorization header: public endpoint; the PAT must never be sent here.

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw AppError.github(status: -1, message: error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw AppError.github(status: -1, message: "No HTTP response while fetching release \(tag).")
        }
        guard http.statusCode == 200 else {
            if http.statusCode == 404 {
                throw AppError.notFound("Runner release \(tag) not found. Check the version number.")
            }
            throw AppError.github(status: http.statusCode, message: "Could not fetch runner release \(tag).")
        }
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(GitHubRelease.self, from: data)
        } catch {
            throw AppError.parse("Failed to parse runner release \(tag): \(error.localizedDescription)")
        }
    }

    // MARK: - Helpers

    /// A cached download is usable iff the file exists AND is non-empty.
    private static func isUsableCachedFile(_ url: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return false }
        let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int
        return (size ?? 0) > 0
    }

    /// Hop a progress line back to the main actor for the UI.
    private static func report(_ progress: @escaping @MainActor (String) -> Void, _ line: String) async {
        Log.info("RunnerUpdater: \(line)")
        await MainActor.run { progress(line) }
    }
}
