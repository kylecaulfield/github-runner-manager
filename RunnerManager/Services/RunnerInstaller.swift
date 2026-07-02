import Foundation

/// A fully-specified request to create (register) a brand-new self-hosted runner on this Mac.
///
/// SECURITY: `registrationToken` is a short-lived (~1h) GitHub registration token — NOT the PAT.
/// It is passed transiently to `config.sh --token` and is never persisted or logged. The PAT is
/// never part of this flow (registration tokens are minted by `AppState`/`GitHubAPI` beforehand,
/// or pasted by the user via the add-runner block).
struct InstallRequest {
    /// Where the runner will be registered (repo / org / enterprise).
    let scope: RunnerScope
    /// Already-minted (Path A) or pasted (Path B) registration token. Transient; never stored.
    let registrationToken: String
    /// Optional runner name. When empty/nil we omit `--name` and let config.sh default to the host name.
    let name: String?
    /// Optional comma-separated ADDITIONAL labels. Omitted when empty/nil.
    let labels: String?
    /// Optional runner group; only meaningful (and only passed) for org/enterprise scopes.
    let runnerGroup: String?
    /// Desired runner version (e.g. "2.335.1"); nil => use the latest published release.
    let version: String?
    /// Parent directory; a fresh unique install subdirectory is created inside this for the new runner.
    let installRoot: URL
}

/// Creates a NEW self-hosted runner: resolve the release asset, download + extract the runner
/// package into a fresh install directory, register it with `config.sh`, then install + start the
/// launchd service via `svc.sh`.
///
/// This type is stateless. Heavy work (download, tar, config.sh, svc.sh) runs off-main via
/// `URLSession`/`ProcessRunner`. Progress is reported back to the caller as human-readable lines.
enum RunnerInstaller {

    /// GitHub's public REST host. Release metadata is fetched here WITHOUT the PAT.
    private static let apiBase = "https://api.github.com"

    /// Full create flow. See the file/type docs above for the high-level steps.
    ///
    /// Returns the freshly-created install directory on success.
    ///
    /// Throws:
    ///  - `AppError.invalidToken` when `config.sh` reports an expired/invalid registration token.
    ///  - `AppError.notFound` when no macOS arm64 asset exists for the resolved release.
    ///  - `AppError.process` / `AppError.io` / `AppError.generic` for download/extract/config/svc failures.
    static func install(
        _ request: InstallRequest,
        downloadCache: URL?,
        progress: @escaping @MainActor (String) -> Void
    ) async throws -> URL {
        // --- 1. Resolve the release asset (specific version, or latest). -------------------------
        await report(progress, request.version.map { "Resolving runner release \($0)…" }
            ?? "Resolving latest runner release…")
        let release = try await resolveRelease(version: request.version)

        guard let asset = release.macOSArm64Asset() else {
            throw AppError.notFound(
                "No macOS arm64 asset (actions-runner-osx-arm64-*.tar.gz) found in runner release \(release.tagName).")
        }
        let resolvedVersion = release.version

        // --- 2. Create a fresh, unique install directory under installRoot. ----------------------
        // The install root is the PARENT; each runner lives in its own subdirectory so multiple
        // runners (even for the same repo) never collide on disk or on their launchd label.
        try AppPaths.ensureDirectory(request.installRoot)
        let installDir = try makeUniqueInstallDirectory(
            in: request.installRoot, scope: request.scope, name: request.name)
        await report(progress, "Created install directory \(installDir.path)")

        // Everything past this point may fail after we've already created `installDir`. On ANY thrown
        // error we remove the freshly-created directory (best-effort) so no orphaned half-install is
        // left behind, then rethrow. We only ever remove the dir WE just created above.
        do {
            // --- 3. Download (reuse cache) + extract the tarball into the install directory. ------
            // Cache the tarball by its asset name so repeat installs/updates of the same version can
            // reuse a prior download. The download deliberately does NOT send the PAT (see download()).
            let cacheDir = downloadCache ?? AppPaths.downloadCache
            try AppPaths.ensureDirectory(cacheDir)
            let tarball = cacheDir.appendingPathComponent(asset.name)

            if isUsableCachedFile(tarball, asset: asset) {
                await report(progress, "Reusing cached download \(asset.name)")
            } else {
                await report(progress, "Downloading \(asset.name)…")
                try await download(asset, to: tarball, progress: progress)
            }

            await report(progress, "Extracting runner package…")
            try await extractTarball(tarball, into: installDir)

            // --- 4. Register the runner with config.sh (unattended). -----------------------------
            await report(progress, "Configuring runner with GitHub…")
            try await runConfig(request: request, in: installDir)

            // --- 5. Install + start the launchd service via svc.sh. ------------------------------
            await report(progress, "Installing launchd service…")
            try await ServiceController.install(at: installDir)
            await report(progress, "Starting runner service…")
            // Build a transient Runner just to drive svc.sh start through ServiceController.
            try await ServiceController.start(RunnerDiscovery.makeRunner(installPath: installDir))

            await report(progress, "Runner \(request.scope.displayName) v\(resolvedVersion) is installed and running.")
            return installDir
        } catch {
            // Clean up only the directory we created in this call; leave the cache/other installs alone.
            try? FileManager.default.removeItem(at: installDir)
            throw error
        }
    }

    /// Download an asset to `destination`, following redirects (URLSession does this by default,
    /// dropping the Authorization header across the host hop to the signed object store).
    ///
    /// SECURITY: this NEVER sends the PAT — `browser_download_url` is public and the request carries
    /// no Authorization header at all. We stream to a temporary file and move it into place so a
    /// partial/failed download never leaves a corrupt file in the cache.
    static func download(
        _ asset: GitHubAsset,
        to destination: URL,
        progress: @escaping @MainActor (String) -> Void
    ) async throws {
        var request = URLRequest(url: asset.browserDownloadUrl)
        request.httpMethod = "GET"
        // Identify ourselves but send NO Authorization header (public asset; PAT must never leak here).
        request.setValue("RunnerManager", forHTTPHeaderField: "User-Agent")

        let tempURL: URL
        let response: URLResponse
        do {
            // `download(for:)` streams to a temp file on disk and follows redirects automatically.
            (tempURL, response) = try await URLSession.shared.download(for: request)
        } catch {
            throw AppError.io("Failed to download \(asset.name): \(error.localizedDescription)")
        }

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw AppError.io("Failed to download \(asset.name): HTTP \(http.statusCode).")
        }

        let fm = FileManager.default
        do {
            // Atomically replace any existing (e.g. zero-byte / stale) file at the destination.
            if fm.fileExists(atPath: destination.path) {
                try fm.removeItem(at: destination)
            }
            try fm.moveItem(at: tempURL, to: destination)
        } catch {
            // Best-effort cleanup of the temp file if the move failed.
            try? fm.removeItem(at: tempURL)
            throw AppError.io("Failed to save download to \(destination.path): \(error.localizedDescription)")
        }

        await report(progress, "Downloaded \(asset.name)")
    }

    /// Extract a `.tar.gz` runner package into `directory` using the system `/usr/bin/tar`.
    ///
    /// The runner tarball contains only `bin/`, `externals/`, and the root scripts (config.sh,
    /// svc.sh, run.sh, …) — it carries NO config/credential files — so extracting it over an
    /// install directory is safe for updates and correct for fresh installs.
    static func extractTarball(_ tarball: URL, into directory: URL) async throws {
        // `tar xzf <tarball> -C <directory>`: x=extract, z=gzip, f=file, -C changes to the target dir.
        let result = try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/tar"),
            arguments: ["xzf", tarball.path, "-C", directory.path],
            currentDirectory: directory,
            throwsOnNonZero: false
        )
        guard result.succeeded else {
            let stderr = result.stderr.isEmpty ? result.stdout : result.stderr
            throw AppError.process(
                command: Log.redact(result.commandLine),
                exitCode: result.exitCode,
                stderr: stderr.isEmpty ? "tar failed to extract \(tarball.lastPathComponent)." : stderr
            )
        }
    }

    // MARK: - Release resolution

    /// Resolve the `GitHubRelease` to install: the latest release when `version` is nil, or the
    /// release tagged `v<version>` otherwise. Both reads are unauthenticated (public endpoints) so
    /// the PAT is never forwarded.
    private static func resolveRelease(version: String?) async throws -> GitHubRelease {
        guard let version, !version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // No specific version requested -> latest published release (token: nil = unauthenticated).
            return try await GitHubAPI(token: nil).latestRelease()
        }

        // A specific version was requested. GitHubAPI exposes only `latestRelease()`, so fetch the
        // tagged release directly from the public releases-by-tag endpoint here.
        // The release TAG carries a leading 'v' (e.g. "v2.335.1"); normalize then re-prefix.
        let normalized = Version.normalize(version)
        let tag = "v\(normalized)"
        return try await releaseByTag(tag)
    }

    /// GET `…/repos/actions/runner/releases/tags/<tag>` (public; no PAT). Decodes a `GitHubRelease`.
    /// 404 -> `AppError.notFound` (the requested version doesn't exist as a published release).
    private static func releaseByTag(_ tag: String) async throws -> GitHubRelease {
        guard let url = URL(string: "\(apiBase)/repos/actions/runner/releases/tags/\(tag)") else {
            throw AppError.generic("Could not build release-by-tag URL for \(tag).")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("RunnerManager", forHTTPHeaderField: "User-Agent")
        // No Authorization header: this is a public endpoint and we deliberately avoid sending the PAT.

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

    // MARK: - config.sh

    /// Run `./config.sh … --unattended --replace` in the freshly-extracted install directory to
    /// register the runner. We pass `--runnergroup` only for org/enterprise scopes (repo scope
    /// rejects it) and `--name`/`--labels` only when non-empty.
    private static func runConfig(request: InstallRequest, in installDir: URL) async throws {
        let configScript = installDir.appendingPathComponent("config.sh")
        guard FileManager.default.isExecutableFile(atPath: configScript.path) else {
            throw AppError.notFound("config.sh not found or not executable at \(configScript.path)")
        }

        var arguments: [String] = [
            "--url", request.scope.webURL,
            "--token", request.registrationToken,
        ]

        // --runnergroup is only valid for org/enterprise; passing it for a repo runner errors out.
        if request.scope.supportsRunnerGroup,
           let group = request.runnerGroup, !group.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            arguments += ["--runnergroup", group]
        }
        // --name only when the user supplied one; otherwise config.sh defaults to the host name.
        if let name = request.name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            arguments += ["--name", name]
        }
        // --labels are ADDITIVE; only pass when non-empty.
        if let labels = request.labels, !labels.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            arguments += ["--labels", labels]
        }
        // --unattended suppresses all stdin prompts; --replace re-registers idempotently on the same name.
        arguments += ["--unattended", "--replace"]

        // Run from the install dir; do NOT throwOnNonZero so we can detect token errors precisely.
        let result = try await ProcessRunner.runScript(
            configScript, arguments,
            currentDirectory: installDir,
            throwsOnNonZero: false
        )

        guard !result.succeeded else { return }

        // config.sh failures: distinguish an expired/invalid registration token from other errors.
        let combined = result.stdout + "\n" + result.stderr
        if looksLikeInvalidToken(combined) {
            throw AppError.invalidToken(
                "The registration token was rejected (it may be expired or invalid — they last about an hour). "
                + "Mint a fresh token and try again.")
        }

        // Otherwise surface the real failure. We do NOT include raw config.sh stdout/stderr: it can
        // contain the registration token, which is not ghp_/github_pat_/40-hex shaped and so cannot be
        // reliably masked by Log.redact (same rationale as AppState.runConfigRemove). The command is
        // redacted (its --token rule masks the token) and we keep the exit code.
        throw AppError.process(
            command: Log.redact(result.commandLine),
            exitCode: result.exitCode,
            stderr: "config.sh failed to register the runner. Output withheld because it may contain the registration token."
        )
    }

    /// Heuristic for "config.sh rejected the registration token (expired/invalid)".
    ///
    /// config.sh prints, on a bad/expired token under `--unattended`:
    ///   "… Terminating unattended configuration" alongside HTTP auth errors (401). We match ONLY
    /// unambiguous auth signals so a token problem is reported as `AppError.invalidToken`. The bare
    /// "invalid"/"expired" substrings were dropped: they misclassify unrelated failures (e.g. a bad
    /// runner group or labels) as token errors.
    private static func looksLikeInvalidToken(_ output: String) -> Bool {
        let lower = output.lowercased()
        return lower.contains("terminating unattended configuration")
            || lower.contains("401")
            || lower.contains("unauthorized")
            || lower.contains("bad credentials")
    }

    // MARK: - Install directory + cache helpers

    /// Create a fresh, unique subdirectory of `installRoot` for a new runner.
    ///
    /// The base name is `<repo-or-org>-<name>` (sanitized), or `<repo-or-org>` when no name was given.
    /// If that directory already exists we append `-<8 hex>` (retrying) so a new install never reuses
    /// or clobbers an existing runner's directory.
    private static func makeUniqueInstallDirectory(
        in installRoot: URL, scope: RunnerScope, name: String?
    ) throws -> URL {
        let fm = FileManager.default

        let scopePart = sanitize(scopeBaseName(scope))
        let namePart: String? = {
            guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
            return sanitize(name)
        }()

        let base: String
        if let namePart, !namePart.isEmpty {
            base = "\(scopePart)-\(namePart)"
        } else {
            base = scopePart
        }
        let baseName = base.isEmpty ? "actions-runner" : base

        // First try the plain base name; if taken, append a short random hex suffix until free.
        var candidate = installRoot.appendingPathComponent(baseName, isDirectory: true)
        var attempts = 0
        while fm.fileExists(atPath: candidate.path) {
            // 8 hex chars from a UUID keeps the suffix short and collision-resistant in practice.
            let suffix = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
            candidate = installRoot.appendingPathComponent("\(baseName)-\(suffix)", isDirectory: true)
            attempts += 1
            if attempts > 50 {
                // ASSUMPTION: this is effectively unreachable; guard against an infinite loop anyway.
                throw AppError.io("Could not allocate a unique install directory under \(installRoot.path).")
            }
        }

        try AppPaths.ensureDirectory(candidate)
        return candidate
    }

    /// A short, human-readable base name for the scope used in the install directory name.
    private static func scopeBaseName(_ scope: RunnerScope) -> String {
        switch scope {
        case let .repo(owner, repo): return "\(owner)-\(repo)"
        case let .org(name): return name
        case let .enterprise(name): return "enterprises-\(name)"
        case .unknown: return "runner"
        }
    }

    /// Sanitize a string for use as a filesystem path component: collapse whitespace to '_' and
    /// replace any character outside `[0-9A-Za-z._-]` with '-'.
    private static func sanitize(_ s: String) -> String {
        let allowed = CharacterSet(charactersIn:
            "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz._-")
        var out = ""
        for scalar in s.unicodeScalars {
            if scalar == " " || scalar == "\t" {
                out.append("_")
            } else if allowed.contains(scalar) {
                out.unicodeScalars.append(scalar)
            } else {
                out.append("-")
            }
        }
        return out
    }

    /// A cached download is usable iff the file exists AND is non-empty. When the release asset
    /// reports a `size`, the cached file must match it exactly — a mismatch means a truncated/partial
    /// prior download, so we re-fetch. When the size is unknown we fall back to the "exists && >0" check.
    private static func isUsableCachedFile(_ url: URL, asset: GitHubAsset) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return false }
        let onDisk = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int
        guard let onDisk, onDisk > 0 else { return false }
        if let expected = asset.size, expected > 0 {
            return onDisk == expected
        }
        return true
    }

    /// Hop a progress line back to the main actor for the UI.
    private static func report(_ progress: @escaping @MainActor (String) -> Void, _ line: String) async {
        Log.info("RunnerInstaller: \(line)")
        await MainActor.run { progress(line) }
    }
}
