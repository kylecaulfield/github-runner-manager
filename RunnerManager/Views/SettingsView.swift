import SwiftUI
import AppKit

/// The app's Settings/Preferences pane (opened via ⌘, or the toolbar "Settings" button).
///
/// Sections:
///   • Search Paths — the directories discovery scans. Add via an `NSOpenPanel` (directory chooser),
///     remove individual entries, and see at a glance whether each resolves to an existing directory.
///   • GitHub PAT — shows ONLY whether a token is set ("A PAT is set" / "No PAT set"). The stored value
///     is NEVER read back or echoed: a `SecureField` lets the user enter a new token, "Save" writes it to
///     the Keychain via `KeychainStore.savePAT`, and "Clear" removes it via `KeychainStore.clearPAT`.
///   • Polling — the status-poll interval (2…60s) via a `Stepper` + `Slider`.
///   • Defaults — default runner group, install root, discovery depth, and log-tail line count.
///
/// SECURITY: the PAT lives only in the Keychain. This view holds the user's freshly-typed token in a
/// transient `@State` SecureField buffer that is cleared the instant it is saved, and it never displays
/// or logs the stored secret.
///
/// `settings` is injected as an `@EnvironmentObject` by the app's `Settings { SettingsView() }` scene
/// (the same `AppSettings` instance shared with the rest of the UI), matching the convention used by the
/// other views. All work here is lightweight and main-thread-safe: Keychain calls are fast, synchronous,
/// and run via `@MainActor` methods; the directory picker uses a modal `NSOpenPanel`.
struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings

    // MARK: - Transient UI state (never persisted)

    /// The token the user is currently typing. Cleared immediately after a successful save.
    /// SECURITY: this is the ONLY place a token lives in this view, and only while being entered.
    @State private var patEntry: String = ""

    /// Whether a PAT currently exists in the Keychain. Reflects `KeychainStore.hasPAT()`; we track it in
    /// state (rather than calling `hasPAT()` in `body`) so the status updates immediately after Save/Clear
    /// without re-querying the Keychain on every render.
    @State private var patIsSet: Bool = false

    /// A transient inline message for the PAT section (e.g. "Saved." or an error). Not a secret.
    @State private var patStatusMessage: String?

    /// Tint for `patStatusMessage`.
    @State private var patStatusIsError: Bool = false

    // MARK: - Startup (Launch at Login) state

    /// Mirrors `LoginItemService.isEnabled`. Seeded on appear and after each toggle so the switch
    /// reflects the actual registration state rather than an optimistic guess.
    @State private var launchAtLogin: Bool = false

    /// A transient inline error for the Launch-at-Login toggle (e.g. SMAppService registration failed).
    @State private var launchAtLoginError: String?

    var body: some View {
        Form {
            searchPathsSection
            patSection
            pollingSection
            defaultsSection
            startupSection
            notificationsSection
            aboutSection
        }
        .formStyle(.grouped)
        .frame(width: 560)
        // A fixed minimum height keeps all sections comfortably visible; the grouped form scrolls if needed.
        .frame(minHeight: 520)
        .onAppear {
            refreshPATStatus()
            // Seed the login-item toggle from the live registration status.
            launchAtLogin = LoginItemService.isEnabled
        }
    }

    // MARK: - Search Paths

    private var searchPathsSection: some View {
        Section {
            if settings.searchPaths.isEmpty {
                Text("No search paths. Add a directory to scan for runner installs.")
                    .font(.callout)
                    .foregroundColor(.secondary)
            } else {
                // One row per configured path, showing whether it resolves to an existing directory.
                ForEach(Array(settings.searchPaths.enumerated()), id: \.offset) { index, path in
                    searchPathRow(path: path, index: index)
                }
            }

            HStack {
                Button {
                    addSearchPath()
                } label: {
                    Label("Add Directory…", systemImage: "plus")
                }

                Spacer()

                Button("Restore Defaults") {
                    settings.searchPaths = AppSettings.defaultSearchPaths
                }
                .help("Reset the search paths to the built-in defaults")
            }
        } header: {
            Text("Search Paths")
        } footer: {
            Text("Directories scanned for runner installs (each contains config.sh, svc.sh, and .runner). "
                 + "A leading ~ expands to your home folder. Missing directories are skipped.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    /// A single search-path row: an existence indicator, the raw path text, the resolved path (when it
    /// differs, e.g. a "~"-expanded path), and a remove button.
    @ViewBuilder
    private func searchPathRow(path: String, index: Int) -> some View {
        let resolved = AppPaths.expandTilde(path)
        let exists = directoryExists(resolved)

        HStack(alignment: .firstTextBaseline, spacing: 8) {
            // Green check for an existing directory, orange triangle for a missing one.
            Image(systemName: exists ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundColor(exists ? .green : .orange)
                .help(exists ? "Directory exists" : "Directory not found")
                .accessibilityLabel(Text(exists ? "Exists" : "Missing"))

            VStack(alignment: .leading, spacing: 2) {
                Text(path)
                    .font(.callout)
                    .textSelection(.enabled)
                // Show the resolved absolute path when it differs from the raw entry (e.g. tilde-expanded),
                // so the user can confirm exactly where we'll look.
                if resolved.path != path {
                    Text(resolved.path)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }
                if !exists {
                    Text("Not found")
                        .font(.caption2)
                        .foregroundColor(.orange)
                }
            }

            Spacer(minLength: 8)

            Button(role: .destructive) {
                removeSearchPath(at: index)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Remove this search path")
            .accessibilityLabel(Text("Remove \(path)"))
        }
    }

    /// Present a directory-only `NSOpenPanel` and append the chosen folder to the search paths.
    /// The panel runs modally on the main thread; selection is fast and non-blocking in practice.
    private func addSearchPath() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.prompt = "Add"
        panel.message = "Choose a directory to scan for self-hosted runners."

        guard panel.runModal() == .OK else { return }

        // Append each chosen directory's absolute path, skipping any we already have.
        var paths = settings.searchPaths
        for url in panel.urls {
            let p = url.standardizedFileURL.path
            if !paths.contains(p) {
                paths.append(p)
            }
        }
        settings.searchPaths = paths
    }

    /// Remove the search path at `index` (bounds-checked).
    private func removeSearchPath(at index: Int) {
        guard settings.searchPaths.indices.contains(index) else { return }
        settings.searchPaths.remove(at: index)
    }

    /// True iff `url` exists and is a directory.
    private func directoryExists(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        return exists && isDir.boolValue
    }

    // MARK: - GitHub PAT

    private var patSection: some View {
        Section {
            // Status line — shows ONLY whether a token is set, never the value.
            HStack(spacing: 8) {
                Image(systemName: patIsSet ? "key.fill" : "key")
                    .foregroundColor(patIsSet ? .green : .secondary)
                    .accessibilityHidden(true)
                Text(patIsSet ? "A PAT is set" : "No PAT set")
                    .font(.callout)
                    .foregroundColor(patIsSet ? .primary : .secondary)
            }

            // Entry field for a NEW token. We never populate this from the stored value.
            SecureField("Fine-grained personal access token", text: $patEntry)
                .textFieldStyle(.roundedBorder)
                // No autocomplete/correction for secrets.
                .autocorrectionDisabled(true)

            HStack {
                Button("Save") {
                    savePAT()
                }
                .keyboardShortcut(.defaultAction)
                // Disable until something has actually been typed.
                .disabled(patEntry.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button("Clear", role: .destructive) {
                    clearPAT()
                }
                .disabled(!patIsSet)

                Spacer()

                if let message = patStatusMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundColor(patStatusIsError ? .red : .secondary)
                        .textSelection(.enabled)
                }
            }
        } header: {
            Text("GitHub PAT")
        } footer: {
            Text("Stored only in your login Keychain — never written to disk, settings, or logs. "
                 + "Used to mint runner registration/remove tokens and to read runner labels. "
                 + "Needs repository (or org/enterprise) Administration: Read and write.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    /// Save the typed token to the Keychain, then immediately clear the in-memory entry buffer.
    private func savePAT() {
        let token = patEntry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }
        do {
            try KeychainStore.savePAT(token)
            // SECURITY: discard the typed value as soon as it is persisted to the Keychain.
            patEntry = ""
            patStatusIsError = false
            patStatusMessage = "Saved."
            refreshPATStatus()
        } catch {
            patStatusIsError = true
            // Surface a human-readable Keychain error; this never contains the token value.
            patStatusMessage = (error as? AppError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Remove the stored token from the Keychain.
    private func clearPAT() {
        do {
            try KeychainStore.clearPAT()
            patEntry = ""
            patStatusIsError = false
            patStatusMessage = "Cleared."
            refreshPATStatus()
        } catch {
            patStatusIsError = true
            patStatusMessage = (error as? AppError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Re-query whether a PAT exists. Uses `hasPAT()` (which discards the value) so we never hold the secret.
    private func refreshPATStatus() {
        patIsSet = KeychainStore.hasPAT()
    }

    // MARK: - Polling

    private var pollingSection: some View {
        Section {
            // Stepper for precise 1-second adjustments; AppSettings clamps to 2…60 on assignment.
            Stepper(value: $settings.pollIntervalSeconds, in: 2...60, step: 1) {
                HStack {
                    Text("Status poll interval")
                    Spacer()
                    Text("\(Int(settings.pollIntervalSeconds.rounded())) s")
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
            }

            // Slider for quick coarse adjustment over the same range.
            Slider(value: $settings.pollIntervalSeconds, in: 2...60, step: 1) {
                Text("Status poll interval")
            } minimumValueLabel: {
                Text("2s").font(.caption).foregroundColor(.secondary)
            } maximumValueLabel: {
                Text("60s").font(.caption).foregroundColor(.secondary)
            }
            .accessibilityLabel(Text("Status poll interval in seconds"))
        } header: {
            Text("Polling")
        } footer: {
            Text("How often RunnerManager re-checks each runner's service status.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Defaults

    private var defaultsSection: some View {
        Section {
            // Default runner group (org/enterprise scopes only; ignored for repo scope).
            LabeledContent("Runner group") {
                TextField("default", text: $settings.defaultRunnerGroup)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                    .autocorrectionDisabled(true)
            }

            // Default install root (parent directory for new installs). A leading ~ expands to home.
            LabeledContent("Install root") {
                TextField("~/actions-runners", text: $settings.defaultInstallRoot)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)
                    .autocorrectionDisabled(true)
            }

            // Discovery recursion depth. AppSettings clamps to 1…6 on assignment.
            Stepper(value: $settings.maxDiscoveryDepth, in: 1...6, step: 1) {
                HStack {
                    Text("Discovery depth")
                    Spacer()
                    Text("\(settings.maxDiscoveryDepth)")
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
            }

            // Number of trailing log lines shown in the log tail view.
            Stepper(value: $settings.logTailLines, in: 50...5000, step: 50) {
                HStack {
                    Text("Log tail lines")
                    Spacer()
                    Text("\(settings.logTailLines)")
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
            }
        } header: {
            Text("Defaults")
        } footer: {
            Text("Defaults applied when creating runners and reading logs. "
                 + "Runner group applies only to organization/enterprise runners.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Startup

    private var startupSection: some View {
        Section {
            Toggle("Launch at login", isOn: $launchAtLogin)
                // Register/unregister the app as a Login Item when the user flips the switch.
                .onChange(of: launchAtLogin) { newValue in
                    // Only act on a genuine USER toggle. Ignore programmatic changes — the
                    // seed-on-appear (launchAtLogin = isEnabled) and the revert-on-failure below both
                    // reassign this binding; without this guard they'd re-enter and cause a spurious
                    // re-registration on every Settings open and would clobber the just-set error.
                    guard newValue != LoginItemService.isEnabled else { return }
                    do {
                        try LoginItemService.setEnabled(newValue)
                        launchAtLoginError = nil
                    } catch {
                        // Revert the visual state to the actual registration status and surface why.
                        launchAtLoginError = (error as? LocalizedError)?.errorDescription
                            ?? error.localizedDescription
                        launchAtLogin = LoginItemService.isEnabled
                    }
                }

            if let launchAtLoginError {
                Text(launchAtLoginError)
                    .font(.caption)
                    .foregroundColor(.red)
                    .textSelection(.enabled)
            }
        } header: {
            Text("Startup")
        } footer: {
            Text("Start RunnerManager automatically when you log in. "
                 + "Ad-hoc or unsigned builds may not persist this reliably.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Notifications

    private var notificationsSection: some View {
        Section {
            Toggle("Enable notifications", isOn: $settings.notificationsEnabled)
                // When turning on, request authorization once (best-effort; failure just means no delivery).
                .onChange(of: settings.notificationsEnabled) { enabled in
                    if enabled {
                        Task { await NotificationService.requestAuthorizationIfNeeded() }
                    }
                }
        } header: {
            Text("Notifications")
        } footer: {
            Text("Post a local notification when a runner stops or an update becomes available. "
                 + "Ad-hoc signing may block delivery; the in-app banner still works either way.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        Section {
            LabeledContent("Version", value: appVersionString)
        } header: {
            Text("About")
        }
    }

    /// "x.y.z (build)" assembled from the bundle's short version + build number. Falls back gracefully
    /// when either key is missing (e.g. a bare test host).
    private var appVersionString: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        switch (short, build) {
        case let (s?, b?): return "\(s) (\(b))"
        case let (s?, nil): return s
        case let (nil, b?): return b
        case (nil, nil): return "Unknown"
        }
    }
}
