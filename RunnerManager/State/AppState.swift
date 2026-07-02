import Foundation
import SwiftUI

/// A transient, dismissible message shown in the UI banner (errors, info, success).
struct BannerMessage: Identifiable, Equatable {
    let id: UUID
    let kind: Kind
    let text: String

    enum Kind { case error, info, success }

    init(id: UUID = UUID(), kind: Kind, text: String) {
        self.id = id
        self.kind = kind
        self.text = text
    }
}

/// Coarse aggregate health of all discovered runners, used to pick the menu-bar icon.
///  - `.empty`: no runners discovered.
///  - `.allRunning`: every runner with a real status is running.
///  - `.someStopped`: at least one runner is stopped / not running (but none errored).
///  - `.error`: at least one runner is in an `.error` state.
enum AggregateHealth { case empty, allRunning, someStopped, error }

/// The app-wide orchestrator. Owns the list of discovered runners and coordinates all the
/// stateless services (discovery, version reading, status, GitHub API, install/update/remove)
/// into the high-level flows the UI invokes.
///
/// THREADING: `AppState` is `@MainActor`, so every published-property mutation happens on the
/// main thread. The heavy work it drives is off-main by construction — `RunnerDiscovery` runs in
/// a `Task.detached`, `ProcessRunner` hops to a background queue, and `URLSession` is async — so
/// awaiting these from the main actor never blocks the UI.
///
/// SECURITY: the PAT is read transiently from the Keychain only at the moment it is needed
/// (`GitHubAPI(token:)`) and is never stored on `self`, logged, or surfaced. Registration/remove
/// tokens are likewise transient. Any command surfaced in an error is redacted by the thrower.
@MainActor
final class AppState: ObservableObject {

    // MARK: - Published state

    /// All discovered runners, enriched with status/version/labels. The UI binds to this.
    @Published private(set) var runners: [Runner] = []

    /// True while a full `refreshAll()` is in flight (drives the refresh spinner).
    @Published private(set) var isRefreshing = false

    /// The current banner message, or nil. Settable so a View can dismiss it.
    @Published var banner: BannerMessage?

    /// The latest published `actions/runner` release, fetched once per refresh and shared by
    /// the whole UI (drives update badges and the "Update All" affordance).
    @Published private(set) var latestRelease: GitHubRelease?

    /// IDs (== install paths) of runners with an action currently in flight, so the UI can
    /// disable that runner's buttons and show a spinner.
    @Published private(set) var busyRunnerIDs: Set<String> = []

    /// Human-readable progress line for long-running create/update flows (download, extract, …).
    @Published private(set) var progressText: String?

    /// Timestamp of the END of the last successful `refreshAll()`, for the "Last refreshed" UI. nil until first refresh.
    @Published private(set) var lastRefreshed: Date?

    /// True while a create flow is in flight. Guards concurrent creates and disables the Create UI.
    @Published private(set) var isCreating: Bool = false

    // MARK: - Dependencies

    /// User settings (search paths, poll interval, defaults). Injected so previews/tests can vary it.
    let settings: AppSettings

    /// The background polling task. `nil` when polling is stopped.
    private var pollingTask: Task<Void, Never>?

    init(settings: AppSettings) {
        self.settings = settings
    }

    // MARK: - Lifecycle

    /// Called when the root view appears: do an initial full refresh, then begin polling.
    func onAppear() {
        Task { await refreshAll() }
        startPolling()
    }

    /// Begin (or restart) the lightweight status-polling loop. Idempotent: an existing loop is
    /// cancelled first so we never run two pollers. The interval honors `settings.pollIntervalSeconds`
    /// and is re-read each tick so changing it in Settings takes effect promptly.
    func startPolling() {
        stopPolling()
        pollingTask = Task { [weak self] in
            // Loop until cancelled (i.e. stopPolling / deinit). We sleep first so the initial
            // refreshAll() from onAppear() isn't immediately followed by a redundant poll.
            while !Task.isCancelled {
                // Read the interval on the main actor each iteration (clamped already in settings).
                let interval = self?.settings.pollIntervalSeconds ?? 5.0
                let nanos = UInt64((interval * 1_000_000_000).rounded())
                do {
                    try await Task.sleep(nanoseconds: nanos)
                } catch {
                    // Sleep throws on cancellation — exit the loop.
                    break
                }
                if Task.isCancelled { break }
                guard let self else { break }
                await self.pollStatuses()
            }
        }
    }

    /// Stop the polling loop, if any.
    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    // MARK: - Refresh

    /// Full refresh:
    ///  1. Filesystem discovery off the main thread (`Task.detached`).
    ///  2. One `latestRelease` fetch (shared by every runner's update check).
    ///  3. Per-runner enrichment (status + installed version) concurrently via a `TaskGroup`.
    ///  4. Label enrichment: one `listRunners` call per distinct scope (requires a PAT).
    ///
    /// Each phase publishes its results as it completes so the UI fills in progressively.
    func refreshAll() async {
        // Re-entrancy guard: a refresh already in flight (e.g. .task-on-open racing the AppDelegate's
        // launch refresh) must not run twice concurrently and clobber each other's in-progress results.
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        // Snapshot pre-refresh state so we can notify only on a genuine *transition* to updateAvailable
        // for a runner we already knew (avoids first-load spam: unknown runners aren't in these sets).
        let previouslyKnownIDs = Set(runners.map { $0.id })
        let previouslyUpdatableIDs = Set(runners.filter { $0.updateAvailable }.map { $0.id })

        // --- 1. Discovery (pure filesystem; run off-main) ---
        // Snapshot the (main-actor) settings before hopping off-main; RunnerDiscovery is pure and
        // takes no actor-isolated state, so it's safe to run detached with these plain values.
        let roots = settings.resolvedSearchPaths()
        let depth = settings.maxDiscoveryDepth
        let discovered = await Task.detached(priority: .userInitiated) {
            RunnerDiscovery.discover(roots: roots, maxDepth: depth)
        }.value

        // Publish the discovered set immediately (status/version/labels still default).
        // Preserve any already-known enrichment for runners we've seen before to avoid UI flicker.
        runners = mergePreservingEnrichment(newlyDiscovered: discovered, previous: runners)

        // --- 2. Latest release (one call; auth optional — releases are public) ---
        // We pass the PAT when available only to raise the rate limit; the release endpoint is public.
        let pat = currentPAT()
        do {
            let release = try await GitHubAPI(token: pat).latestRelease()
            latestRelease = release
            // Stamp the latest version onto every runner so update badges can compute.
            let latest = release.version
            for index in runners.indices {
                runners[index].latestVersion = latest
            }
        } catch {
            // A failed release fetch is non-fatal: we just can't show update availability.
            // Surface it quietly as info (not error) so it doesn't dominate the UI.
            Log.error("refreshAll: latestRelease failed: \(error.localizedDescription)")
            note("Couldn't check for the latest runner release. Update availability may be stale.", kind: .info)
        }

        // --- 3. Per-runner enrichment: status + installed version, concurrently ---
        // Capture a snapshot of (id, runner) so the TaskGroup work is independent of `self`'s array.
        let snapshot = runners
        let enriched: [(id: String, status: RunnerStatus, version: String?)] =
            await withTaskGroup(of: (String, RunnerStatus, String?).self) { group in
                for runner in snapshot {
                    group.addTask {
                        // ServiceController.status never throws (reports .error). VersionReader never throws.
                        async let status = ServiceController.status(for: runner)
                        async let version = VersionReader.installedVersion(at: runner.installPath)
                        return (runner.id, await status, await version)
                    }
                }
                var results: [(String, RunnerStatus, String?)] = []
                for await result in group {
                    results.append(result)
                }
                return results
            }
        applyEnrichment(enriched)

        // Notify on a real transition to updateAvailable for a previously-known runner (the in-app
        // Update badge remains the reliable fallback). Skips first-load / brand-new runners.
        if settings.notificationsEnabled {
            for runner in runners
            where runner.updateAvailable
                && previouslyKnownIDs.contains(runner.id)
                && !previouslyUpdatableIDs.contains(runner.id) {
                NotificationService.post(
                    title: "Runner update available",
                    body: "\(runner.name) can be updated to \(runner.latestVersion ?? "the latest release")."
                )
            }
        }

        // --- 4. Labels: one listRunners per distinct scope (needs a PAT) ---
        await refreshLabels(pat: pat)

        // Stamp completion LAST (after all enrichment) so "Last refreshed" reflects a full pass.
        lastRefreshed = Date()
    }

    /// Lightweight poll: re-run only `ServiceController.status` for each known runner, concurrently.
    /// Does NOT re-discover, re-fetch the release, re-read versions, or re-fetch labels — those are
    /// the expensive/rarely-changing parts handled by `refreshAll()`.
    func pollStatuses() async {
        // Skip polling while a full refresh is running to avoid clobbering its in-progress results.
        guard !isRefreshing else { return }
        let snapshot = runners
        guard !snapshot.isEmpty else { return }

        let statuses: [(id: String, status: RunnerStatus)] =
            await withTaskGroup(of: (String, RunnerStatus).self) { group in
                for runner in snapshot {
                    group.addTask {
                        (runner.id, await ServiceController.status(for: runner))
                    }
                }
                var results: [(String, RunnerStatus)] = []
                for await result in group {
                    results.append(result)
                }
                return results
            }

        // Apply by id (the array may have changed underneath us between snapshot and now).
        for (id, status) in statuses {
            if let index = runners.firstIndex(where: { $0.id == id }) {
                // Detect a genuine running -> stopped transition BEFORE overwriting so we can notify.
                // Skip runners mid user-action (busy): a poll racing the user's own stop/restart must
                // not fire a spurious "stopped" notification for something they just did.
                let previous = runners[index].status
                if settings.notificationsEnabled, !busyRunnerIDs.contains(id),
                   previous.isRunning, status == .stopped {
                    NotificationService.post(
                        title: "Runner stopped",
                        body: "\(runners[index].name) is no longer running."
                    )
                }
                runners[index].status = status
            }
        }
    }

    // MARK: - Per-runner actions

    /// Start a runner's service, then refresh just that runner's status.
    func start(_ r: Runner) async {
        await performRunnerAction(r) { runner in
            try await ServiceController.start(runner)
        }
    }

    /// Stop a runner's service, then refresh just that runner's status.
    func stop(_ r: Runner) async {
        await performRunnerAction(r) { runner in
            try await ServiceController.stop(runner)
        }
    }

    /// Restart a runner's service (stop then start), then refresh just that runner's status.
    func restart(_ r: Runner) async {
        await performRunnerAction(r) { runner in
            try await ServiceController.restart(runner)
        }
    }

    /// Update a single runner's binaries in place (preserving registration), then refresh it.
    /// Target version is the latest release; `RunnerUpdater` skips if already at target.
    func update(_ r: Runner) async {
        guard !busyRunnerIDs.contains(r.id) else { return }
        busyRunnerIDs.insert(r.id)
        progressText = nil
        defer {
            busyRunnerIDs.remove(r.id)
            progressText = nil
        }
        do {
            // nil target => RunnerUpdater resolves the latest release itself.
            try await RunnerUpdater.update(
                r,
                to: latestRelease?.version,
                downloadCache: AppPaths.downloadCache
            ) { [weak self] line in
                // @MainActor closure: safe to touch published state directly.
                self?.progressText = line
            }
            note("Updated \(r.name).", kind: .success)
        } catch {
            report(error)
        }
        // Re-read status (and version) for this runner so the UI reflects the new binaries.
        await refreshSingleRunner(id: r.id, includeVersion: true)
    }

    /// Update every runner that currently reports an available update, sequentially (to avoid
    /// hammering the network/disk and to keep `progressText` coherent for the user).
    func updateAll() async {
        let targets = runners.filter { $0.updateAvailable }
        guard !targets.isEmpty else {
            note("All runners are up to date.", kind: .info)
            return
        }
        for runner in targets {
            // Re-fetch the live runner by id in case earlier updates changed the array.
            guard let current = runners.first(where: { $0.id == runner.id }) else { continue }
            await update(current)
        }
        note("Finished updating \(targets.count) runner\(targets.count == 1 ? "" : "s").", kind: .success)
    }

    /// Start every runner that is installed-but-stopped. Sequential (reuses `start`/`performRunnerAction`
    /// so each runner is marked busy and refreshed); runners already busy are skipped by that plumbing.
    /// We target ONLY `.stopped` (not `.notInstalled`/`.error`/`.unknown`): starting a not-installed
    /// service just fails and would spam error banners — and every runner is `.unknown` before the first
    /// enrichment completes.
    func startAll() async {
        let targets = runners.filter { $0.status == .stopped && !busyRunnerIDs.contains($0.id) }
        for runner in targets {
            // Re-fetch the live runner by id in case the array changed between iterations.
            guard let current = runners.first(where: { $0.id == runner.id }) else { continue }
            await start(current)
        }
    }

    /// Stop every runner that is currently running. Sequential (reuses `stop`/`performRunnerAction`);
    /// runners already busy are skipped by that plumbing.
    func stopAll() async {
        let targets = runners.filter { $0.status.isRunning && !busyRunnerIDs.contains($0.id) }
        for runner in targets {
            guard let current = runners.first(where: { $0.id == runner.id }) else { continue }
            await stop(current)
        }
    }

    /// Remove (de-register) a runner and tear down its service.
    ///
    /// Flow (per spec):
    ///  1. `./svc.sh stop` then `./svc.sh uninstall` FIRST (best-effort — a stopped/already-removed
    ///     service shouldn't block de-registration).
    ///  2. De-register on GitHub:
    ///     - If a PAT is present, mint a fresh remove-token and run `./config.sh remove --token <t>`.
    ///       Also DELETE via the API by `agentId` as a backstop so the registration is gone even if
    ///       config.sh's call is flaky.
    ///     - If no PAT, run `./config.sh remove --local` (on-disk config only; no GitHub call).
    ///  3. If `deleteDirectory`, remove the install directory last.
    ///  4. Drop the runner from the list (or refresh it) on success.
    func remove(_ r: Runner, deleteDirectory: Bool) async {
        guard !busyRunnerIDs.contains(r.id) else { return }
        busyRunnerIDs.insert(r.id)
        defer { busyRunnerIDs.remove(r.id) }

        // 1. Stop + uninstall the launchd service FIRST. Best-effort: a service that's already
        //    stopped/uninstalled must not prevent de-registration, so we swallow these errors.
        do {
            try await ServiceController.stop(r)
        } catch {
            Log.error("remove: svc.sh stop failed (continuing): \(error.localizedDescription)")
        }
        do {
            try await ServiceController.uninstall(at: r.installPath)
        } catch {
            Log.error("remove: svc.sh uninstall failed (continuing): \(error.localizedDescription)")
        }

        // 2. De-register on GitHub.
        let pat = currentPAT()
        do {
            if let pat, !pat.isEmpty, r.scope.apiBasePath != nil {
                // Mint a fresh remove-token immediately before shelling out (tokens last ~1h).
                let api = GitHubAPI(token: pat)
                let removeToken = try await api.removeToken(scope: r.scope)
                try await runConfigRemove(at: r.installPath, arguments: ["remove", "--token", removeToken.token])

                // Backstop: also delete via the API by agentId so the registration is definitely gone.
                if let agentId = r.config?.agentId {
                    // Non-fatal if this fails (config.sh remove likely already de-registered).
                    do {
                        try await api.deleteRunner(scope: r.scope, id: agentId)
                    } catch {
                        Log.error("remove: API deleteRunner backstop failed (non-fatal): \(error.localizedDescription)")
                    }
                }
            } else {
                // No usable PAT (or unparseable scope): remove the on-disk config only.
                // ASSUMPTION: without a PAT we cannot mint a remove-token, so we use --local; the
                // operator must remove the now-offline runner from GitHub's UI if desired.
                try await runConfigRemove(at: r.installPath, arguments: ["remove", "--local"])
            }
        } catch {
            // config.sh remove failed. De-register via the API by agentId INDEPENDENTLY of config.sh's
            // outcome so the registration is still torn down. Best-effort — swallow any API error.
            if let pat, !pat.isEmpty, r.scope.apiBasePath != nil, let agentId = r.config?.agentId {
                try? await GitHubAPI(token: pat).deleteRunner(scope: r.scope, id: agentId)
            }
            report(error)
            // Even on de-registration failure, refresh status so the UI reflects the stopped service.
            await refreshSingleRunner(id: r.id, includeVersion: false)
            return
        }

        // 3. Optionally delete the install directory (last, and only after successful de-register).
        if deleteDirectory {
            do {
                try FileManager.default.removeItem(at: r.installPath)
            } catch {
                report(AppError.io("Removed the runner registration, but could not delete the install directory at \(r.installPath.path): \(error.localizedDescription)"))
                // The directory remains; refresh its (now not-installed) status rather than dropping it.
                await refreshSingleRunner(id: r.id, includeVersion: false)
                return
            }
        }

        // 4. Success.
        if deleteDirectory {
            // The install dir is gone — drop the runner from the list.
            runners.removeAll { $0.id == r.id }
            note("Removed \(r.name) and deleted its install directory.", kind: .success)
        } else {
            // Directory kept — refresh so it shows as de-registered / not installed.
            await refreshSingleRunner(id: r.id, includeVersion: false)
            note("Removed \(r.name).", kind: .success)
        }
    }

    // MARK: - Create flows

    /// Create a new runner using the stored PAT (Path A).
    ///
    /// Reads the PAT from the Keychain, mints a registration token for the chosen scope, then runs
    /// the full install flow (download + extract + config.sh + svc.sh install/start). On success the
    /// new runner is discovered into the list.
    ///
    /// - Parameters:
    ///   - owner: repo owner OR the org/enterprise login (when `isOrg` is true, the org name).
    ///   - repo: repository name (ignored when `isOrg` is true).
    ///   - isOrg: true to register an organization runner (scope = .org(owner)); false for repo scope.
    func createRunnerWithPAT(owner: String, repo: String, isOrg: Bool, name: String?, labels: String?,
                             runnerGroup: String?, installRoot: URL) async {
        // Guard against concurrent creates (also disables the Create UI while in flight).
        guard !isCreating else { return }
        isCreating = true
        progressText = nil
        defer {
            isCreating = false
            progressText = nil
        }

        // Require a PAT for this path; tokens are minted server-side via the API.
        guard let pat = currentPAT(), !pat.isEmpty else {
            note("Set a GitHub PAT in Settings (or use the Paste-block tab) to create a runner this way.", kind: .error)
            return
        }

        let trimmedOwner = owner.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedRepo = repo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedOwner.isEmpty else {
            note(isOrg ? "Enter an organization name." : "Enter a repository owner.", kind: .error)
            return
        }
        // Build the scope. For org runners we ignore `repo`; for repo runners both are required.
        let scope: RunnerScope
        if isOrg {
            scope = .org(trimmedOwner)
        } else {
            guard !trimmedRepo.isEmpty else {
                note("Enter a repository name.", kind: .error)
                return
            }
            scope = .repo(owner: trimmedOwner, repo: trimmedRepo)
        }

        progressText = "Requesting a registration token from GitHub…"
        do {
            // Mint the (transient, ~1h) registration token immediately before installing.
            let registration = try await GitHubAPI(token: pat).registrationToken(scope: scope)
            let request = InstallRequest(
                scope: scope,
                registrationToken: registration.token,
                name: trimmedNonEmpty(name),
                labels: trimmedNonEmpty(labels),
                // --runnergroup only applies to org/enterprise scopes; suppress it for repo scope.
                runnerGroup: scope.supportsRunnerGroup ? trimmedNonEmpty(runnerGroup) : nil,
                version: nil,                 // nil => latest release
                installRoot: installRoot
            )
            try await runInstall(request)
        } catch {
            report(error)
        }
    }

    /// Create a new runner from the block GitHub shows on "Add new self-hosted runner" (Path B).
    ///
    /// Parses the pasted block for the `--url`, registration `--token`, and (optionally) version,
    /// then runs the full install flow. Works WITHOUT a stored PAT because the token is already in
    /// the block. The user may override name/labels/group/installRoot.
    func createRunnerFromBlock(_ pastedText: String, name: String?, labels: String?,
                               runnerGroup: String?, installRoot: URL) async {
        // Guard against concurrent creates (also disables the Create UI while in flight).
        guard !isCreating else { return }
        isCreating = true
        progressText = nil
        defer {
            isCreating = false
            progressText = nil
        }

        do {
            // BlockParser throws AppError.parse if url/token are missing; it never logs the token.
            let parsed = try BlockParser.parse(pastedText)
            let scope = parsed.scope
            let request = InstallRequest(
                scope: scope,
                registrationToken: parsed.token,
                name: trimmedNonEmpty(name),
                labels: trimmedNonEmpty(labels),
                runnerGroup: scope.supportsRunnerGroup ? trimmedNonEmpty(runnerGroup) : nil,
                version: parsed.version,      // honor the version embedded in the block if present
                installRoot: installRoot
            )
            try await runInstall(request)
        } catch {
            report(error)
        }
    }

    // MARK: - Aggregate health

    /// Coarse health used to choose the menu-bar icon. Precedence:
    ///  - no runners                                  → `.empty`
    ///  - any runner errored                          → `.error`
    ///  - every runner is running                     → `.allRunning`
    ///  - otherwise (any stopped / not-yet-confirmed) → `.someStopped`
    ///
    /// We deliberately require EVERY runner to be `.running` for `.allRunning`: a runner that is
    /// stopped, not-installed, or still `.unknown` (mid-first-refresh) should not show an all-clear.
    var aggregateHealth: AggregateHealth {
        guard !runners.isEmpty else { return .empty }

        if runners.contains(where: { if case .error = $0.status { return true } else { return false } }) {
            return .error
        }

        // All-clear only when every runner reports running; anything else is "someStopped".
        if runners.allSatisfy({ $0.status.isRunning }) {
            return .allRunning
        }
        return .someStopped
    }

    // MARK: - Banner helpers

    /// Map any error into a `.error` banner, redacting any command text it carries.
    /// `AppError.process` already stores a redacted command; for other errors we redact the
    /// localized description defensively in case it interpolated a command/token.
    func report(_ error: Error) {
        // Cancellation is not a user-facing error.
        if error is CancellationError { return }
        if case AppError.cancelled = error { return }

        let message: String
        if let appError = error as? AppError {
            message = appError.errorDescription ?? "An error occurred."
        } else {
            message = error.localizedDescription
        }
        Log.error("report: \(message)")
        banner = BannerMessage(kind: .error, text: Log.redact(message))
    }

    /// Post a non-error informational/success banner.
    func note(_ text: String, kind: BannerMessage.Kind) {
        banner = BannerMessage(kind: kind, text: Log.redact(text))
    }

    // MARK: - Private: action plumbing

    /// Shared scaffolding for a single-runner service action: mark busy, run the work (mapping
    /// errors to a banner), then refresh that runner's status, then clear busy.
    private func performRunnerAction(_ r: Runner, _ work: @escaping (Runner) async throws -> Void) async {
        guard !busyRunnerIDs.contains(r.id) else { return }
        busyRunnerIDs.insert(r.id)
        defer { busyRunnerIDs.remove(r.id) }
        do {
            try await work(r)
        } catch {
            report(error)
        }
        // Always refresh status afterward — even on failure the live state may have changed.
        await refreshSingleRunner(id: r.id, includeVersion: false)
    }

    /// Run the full install flow for a request and fold the new runner into the list on success.
    /// Shared by both create paths. Surfaces progress via `progressText`.
    private func runInstall(_ request: InstallRequest) async throws {
        // Ensure the parent install root exists before handing off to the installer.
        try AppPaths.ensureDirectory(request.installRoot)

        let newInstallDir = try await RunnerInstaller.install(
            request,
            downloadCache: AppPaths.downloadCache
        ) { [weak self] line in
            self?.progressText = line
        }

        // Build the freshly-created runner from disk and enrich it, then merge into the list.
        let newRunner = RunnerDiscovery.makeRunner(installPath: newInstallDir)
        if let index = runners.firstIndex(where: { $0.id == newRunner.id }) {
            // Replace an existing entry (e.g. a --replace re-register of the same path).
            runners[index] = preservingEnrichment(new: newRunner, old: runners[index])
        } else {
            runners.append(newRunner)
        }
        // Stamp the latest version we already know so the update badge is correct immediately.
        if let latest = latestRelease?.version, let index = runners.firstIndex(where: { $0.id == newRunner.id }) {
            runners[index].latestVersion = latest
        }
        await refreshSingleRunner(id: newRunner.id, includeVersion: true)
        await refreshLabels(pat: currentPAT())

        note("Created runner \(newRunner.name).", kind: .success)
    }

    /// Run `./config.sh remove …` from the install directory, mapping an invalid/expired remove-token
    /// to `AppError.invalidToken` and everything else to `AppError.process` (with a redacted command).
    private func runConfigRemove(at installPath: URL, arguments: [String]) async throws {
        let configScript = installPath.appendingPathComponent("config.sh")
        guard FileManager.default.isExecutableFile(atPath: configScript.path) else {
            throw AppError.notFound("config.sh not found or not executable at \(configScript.path)")
        }
        let result = try await ProcessRunner.runScript(
            configScript, arguments,
            currentDirectory: installPath,
            throwsOnNonZero: false
        )
        guard !result.succeeded else { return }

        let combined = (result.stdout + "\n" + result.stderr)
        let lower = combined.lowercased()
        // config.sh signals a bad token via the unattended-termination message / HTTP auth errors.
        if lower.contains("terminating unattended configuration")
            || lower.contains("401")
            || lower.contains("invalid")
            || lower.contains("expired") {
            // Use a STATIC message here: `combined` is the raw config.sh output produced while the
            // live remove-token was on the command line. Remove tokens are not ghp_/github_pat_/40-hex
            // shaped, so Log.redact cannot reliably mask them — never interpolate that output into a
            // message that flows to the banner/log. (Mirrors RunnerInstaller's token-failure handling.)
            throw AppError.invalidToken(
                "The remove token was rejected (it may be expired — remove tokens last about an hour). Mint a fresh token and try again."
            )
        }
        // SECURITY: do NOT surface raw stdout/stderr here. config.sh ran with the live remove-token on
        // its command line and may echo it in a shape Log.redact can't reliably mask (remove tokens are
        // not ghp_/github_pat_/40-hex). Pass a generic detail; keep the exit code. (The command field is
        // safe — Log.redact masks the "--token <value>" argument.)
        throw AppError.process(
            command: Log.redact(result.commandLine),
            exitCode: result.exitCode,
            stderr: "config.sh remove failed (exit \(result.exitCode)). Output withheld because it may contain the remove token."
        )
    }

    // MARK: - Private: enrichment

    /// Re-read status (and optionally installed version) for a single runner by id and apply it.
    private func refreshSingleRunner(id: String, includeVersion: Bool) async {
        guard let runner = runners.first(where: { $0.id == id }) else { return }
        let status = await ServiceController.status(for: runner)
        let version: String? = includeVersion
            ? await VersionReader.installedVersion(at: runner.installPath)
            : nil

        guard let index = runners.firstIndex(where: { $0.id == id }) else { return }
        runners[index].status = status
        // Only assign a non-nil version so a transient nil read doesn't wipe a known version
        // (which would flicker the Update badge).
        if includeVersion, let v = version {
            runners[index].installedVersion = v
        }
    }

    /// Apply a batch of (id, status, version) enrichment results to the runner list by id.
    private func applyEnrichment(_ enriched: [(id: String, status: RunnerStatus, version: String?)]) {
        for item in enriched {
            if let index = runners.firstIndex(where: { $0.id == item.id }) {
                runners[index].status = item.status
                // Only assign a non-nil version so a transient nil read doesn't wipe a known version
                // (which would flicker the Update badge).
                if let v = item.version { runners[index].installedVersion = v }
            }
        }
    }

    /// Label enrichment: group the current runners by scope and make ONE `listRunners` call per
    /// distinct scope (labels are server-side only). Match API runners to local runners by name and
    /// copy their labels. No-ops (leaving labels empty) when no PAT is available.
    private func refreshLabels(pat: String?) async {
        guard let pat, !pat.isEmpty else {
            // ASSUMPTION: without a PAT we cannot read server-side labels; leave them empty and let
            // the UI explain that labels require a PAT. We do NOT clear previously-known labels here.
            return
        }

        // Distinct scopes that have a usable API path (skip .unknown).
        let scopes = Set(runners.map { $0.scope }).filter { $0.apiBasePath != nil }
        guard !scopes.isEmpty else { return }

        let api = GitHubAPI(token: pat)

        // Fetch each scope's runners concurrently (one call per scope), collecting name->APIRunner maps
        // so we can copy labels AND the server-side status/busy onto each matching local runner.
        let perScope: [(scope: RunnerScope, byName: [String: APIRunner])] =
            await withTaskGroup(of: (RunnerScope, [String: APIRunner]?).self) { group in
                for scope in scopes {
                    group.addTask {
                        do {
                            let apiRunners = try await api.listRunners(scope: scope)
                            // Map runner name -> its full API record (order preserved from the API).
                            var byName: [String: APIRunner] = [:]
                            for apiRunner in apiRunners {
                                byName[apiRunner.name] = apiRunner
                            }
                            return (scope, byName)
                        } catch {
                            // A failed scope (e.g. PAT lacks Administration for it) is non-fatal:
                            // other scopes still enrich. Log quietly; leave those labels untouched.
                            Log.error("refreshLabels: listRunners failed for \(scope.displayName): \(error.localizedDescription)")
                            return (scope, nil)
                        }
                    }
                }
                var results: [(RunnerScope, [String: APIRunner])] = []
                for await (scope, map) in group {
                    if let map { results.append((scope, map)) }
                }
                return results
            }

        // Apply: for each runner, look up its scope's map, match by name, and copy labels + API state.
        let maps = Dictionary(perScope.map { ($0.scope, $0.byName) }, uniquingKeysWith: { first, _ in first })
        for index in runners.indices {
            let runner = runners[index]
            if let byName = maps[runner.scope], let apiRunner = byName[runner.name] {
                runners[index].labels = apiRunner.labels.map(\.name)
                // Capture server-side state alongside labels (drives the GitHub online/busy badges).
                runners[index].apiStatus = apiRunner.status
                runners[index].apiBusy = apiRunner.busy
            }
        }
    }

    // MARK: - Private: merge helpers

    /// Merge a freshly-discovered set with the previous list, preserving the enriched fields
    /// (status, versions, labels) of runners we already knew so the UI doesn't flicker back to
    /// "unknown" while a refresh is in progress. New runners come in with defaults.
    private func mergePreservingEnrichment(newlyDiscovered: [Runner], previous: [Runner]) -> [Runner] {
        let previousByID = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return newlyDiscovered.map { fresh in
            if let old = previousByID[fresh.id] {
                return preservingEnrichment(new: fresh, old: old)
            }
            return fresh
        }
    }

    /// Copy the enriched (async-filled) fields from `old` onto a freshly-rebuilt `new` runner.
    /// Discovery-time fields come from `new` (they reflect the current on-disk state).
    private func preservingEnrichment(new: Runner, old: Runner) -> Runner {
        var merged = new
        merged.status = old.status
        merged.installedVersion = old.installedVersion
        merged.latestVersion = old.latestVersion
        merged.labels = old.labels
        // Preserve server-side API state too (populated alongside labels by refreshLabels) so the
        // GitHub online/busy badge doesn't flicker to unknown while a refresh is re-discovering.
        merged.apiStatus = old.apiStatus
        merged.apiBusy = old.apiBusy
        return merged
    }

    // MARK: - Private: PAT + small utilities

    /// Read the PAT transiently from the Keychain. Returns nil on absence or any Keychain error
    /// (a Keychain failure shouldn't break refresh; PAT-requiring features just degrade).
    /// SECURITY: the returned value is used immediately by a `GitHubAPI` instance and never stored.
    private func currentPAT() -> String? {
        do {
            return try KeychainStore.readPAT()
        } catch {
            Log.error("currentPAT: Keychain read failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Trim a possibly-nil string; return nil if it is nil or becomes empty after trimming.
    /// Used so we only pass `--name`/`--labels`/`--runnergroup` when the user actually provided one.
    private func trimmedNonEmpty(_ s: String?) -> String? {
        guard let s else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
