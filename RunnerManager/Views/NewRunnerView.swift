import SwiftUI

/// The "New Runner" sheet. Presents two ways to register a self-hosted runner, in a `TabView`:
///
///  - **Stored PAT** (Path A): the user types the owner/repo (or org), optional name/labels/group
///    and an install root. We mint a registration token server-side via the stored PAT and run the
///    full install. Requires a PAT in the Keychain — if none is set, we show a notice and disable
///    Create.
///  - **Paste block** (Path B): the user pastes the shell block GitHub shows on "Add new
///    self-hosted runner". We parse `--url` / `--token` / version locally (no PAT needed, the token
///    is already in the block) and run the same install. A live preview shows the parsed scope and
///    version so the user can confirm before creating.
///
/// Both tabs delegate the actual work to `AppState` (`createRunnerWithPAT` / `createRunnerFromBlock`),
/// which runs everything off-main and surfaces progress through `appState.progressText` and a
/// success/error `banner`. This view only collects input, shows progress, and dismisses on success.
///
/// SECURITY: the pasted block contains a short-lived *registration* token (not a PAT). It lives only
/// in this view's transient `@State` while the sheet is open and is handed straight to `AppState`,
/// which passes it transiently to `config.sh`. We never persist or log it. The stored PAT is read
/// only inside `AppState`/`KeychainStore`; this view only asks `KeychainStore.hasPAT()` (a Bool).
struct NewRunnerView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    /// Which tab is selected.
    private enum Tab: Hashable { case storedPAT, pasteBlock }
    @State private var selectedTab: Tab = .storedPAT

    // MARK: - Stored-PAT (Path A) form state

    @State private var owner: String = ""
    @State private var repo: String = ""
    @State private var isOrg: Bool = false
    @State private var patName: String = ""
    @State private var patLabels: String = ""
    @State private var patRunnerGroup: String = ""
    @State private var patInstallRoot: String = ""

    // MARK: - Paste-block (Path B) form state

    @State private var pastedBlock: String = ""
    @State private var blockName: String = ""
    @State private var blockLabels: String = ""
    @State private var blockRunnerGroup: String = ""
    @State private var blockInstallRoot: String = ""

    // MARK: - Shared transient UI state

    /// True while a create flow is in flight (disables inputs/buttons, shows progress).
    @State private var isCreating = false

    /// Whether the PAT is present, snapshotted on appear so the notice is stable while the sheet
    /// is open. (We avoid calling the Keychain on every render.)
    @State private var hasPAT: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            header

            TabView(selection: $selectedTab) {
                storedPATTab
                    .tabItem { Label("Stored PAT", systemImage: "key.fill") }
                    .tag(Tab.storedPAT)

                pasteBlockTab
                    .tabItem { Label("Paste block", systemImage: "doc.on.clipboard") }
                    .tag(Tab.pasteBlock)
            }
            .padding(.top, 8)

            Divider()

            footer
        }
        .frame(width: 560, height: 560)
        .onAppear {
            // Snapshot PAT presence and seed the per-tab install roots / group from settings.
            hasPAT = KeychainStore.hasPAT()
            if patInstallRoot.isEmpty { patInstallRoot = settings.defaultInstallRoot }
            if blockInstallRoot.isEmpty { blockInstallRoot = settings.defaultInstallRoot }
            if patRunnerGroup.isEmpty { patRunnerGroup = settings.defaultRunnerGroup }
            if blockRunnerGroup.isEmpty { blockRunnerGroup = settings.defaultRunnerGroup }
        }
    }

    // MARK: - Header / footer

    private var header: some View {
        HStack {
            Text("New Runner")
                .font(.title2.weight(.semibold))
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
    }

    /// Bottom bar: live progress (while creating), then Cancel / Create.
    private var footer: some View {
        HStack(spacing: 12) {
            // Progress line surfaced by AppState during download/extract/config/install.
            if isCreating {
                ProgressView().controlSize(.small)
                Text(appState.progressText ?? "Working…")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(isCreating)

            Button("Create") {
                createCurrentTab()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(isCreating || !canCreateCurrentTab)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Tab A: Stored PAT

    private var storedPATTab: some View {
        Form {
            if !hasPAT {
                // No PAT stored: this path can't mint a registration token. Tell the user how to
                // proceed (set a PAT in Settings, or switch to the Paste-block tab).
                Section {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("No GitHub PAT is set.")
                                .font(.callout.weight(.semibold))
                            Text("Set a fine-grained PAT (Administration: Read and write) in Settings to create a runner this way, or use the Paste block tab — its registration token works without a stored PAT.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Button("Use Paste block tab") { selectedTab = .pasteBlock }
                                .buttonStyle(.link)
                                .padding(.top, 2)
                        }
                    }
                }
            }

            Section("Target") {
                Toggle("Organization runner", isOn: $isOrg)
                    .help("Register at the organization level instead of a single repository.")

                TextField(isOrg ? "Organization" : "Owner", text: $owner)
                    .textFieldStyle(.roundedBorder)
                    .help(isOrg ? "The organization login (e.g. my-org)." : "The repository owner (user or org).")

                if !isOrg {
                    TextField("Repository", text: $repo)
                        .textFieldStyle(.roundedBorder)
                        .help("The repository name (without the owner).")
                }
            }

            Section("Options") {
                TextField("Name (optional)", text: $patName)
                    .textFieldStyle(.roundedBorder)
                    .help("Runner name. Defaults to the machine name if left blank.")

                TextField("Labels (optional, comma-separated)", text: $patLabels)
                    .textFieldStyle(.roundedBorder)
                    .help("Additional labels, comma-separated. Added on top of the default labels.")

                // --runnergroup is only valid for org/enterprise scopes; hide it for repo runners.
                if isOrg {
                    TextField("Runner group (optional)", text: $patRunnerGroup)
                        .textFieldStyle(.roundedBorder)
                        .help("Runner group for org/enterprise runners. Defaults to \"default\".")
                }

                installRootField(text: $patInstallRoot)
            }
        }
        .formStyle(.grouped)
        .disabled(isCreating)
    }

    // MARK: - Tab B: Paste block

    private var pasteBlockTab: some View {
        Form {
            Section("Paste the \"Add new self-hosted runner\" block") {
                Text("Copy the shell block GitHub shows on the runner setup page (the lines with ./config.sh --url … --token …) and paste it below. Works without a stored PAT.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // Monospaced editor for the pasted shell block. The registration token it contains
                // is transient (~1h) and is never persisted or logged.
                TextEditor(text: $pastedBlock)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 140)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 0.5)
                    )
                    .autocorrectionDisabled(true)

                // Live parse preview: classify scope (owner/repo or org) and show the version when
                // the block parses. Errors here are expected while the user is still typing.
                blockPreview
            }

            Section("Options") {
                TextField("Name (optional)", text: $blockName)
                    .textFieldStyle(.roundedBorder)
                    .help("Override the runner name. Defaults to the machine name if left blank.")

                TextField("Labels (optional, comma-separated)", text: $blockLabels)
                    .textFieldStyle(.roundedBorder)
                    .help("Additional labels, comma-separated.")

                // Only show the runner-group field when the parsed scope supports it (org/enterprise).
                if parsedBlock?.scope.supportsRunnerGroup == true {
                    TextField("Runner group (optional)", text: $blockRunnerGroup)
                        .textFieldStyle(.roundedBorder)
                        .help("Runner group for org/enterprise runners. Defaults to \"default\".")
                }

                installRootField(text: $blockInstallRoot)
            }
        }
        .formStyle(.grouped)
        .disabled(isCreating)
    }

    /// The live preview row under the TextEditor: shows the parsed scope + version, or a hint.
    @ViewBuilder
    private var blockPreview: some View {
        let trimmed = pastedBlock.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            Label("Paste a block to see its parsed target.", systemImage: "info.circle")
                .font(.caption)
                .foregroundColor(.secondary)
        } else if let parsed = parsedBlock {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Target: \(parsed.scope.displayName)")
                        .font(.caption.weight(.semibold))
                    Text(parsed.version.map { "Version: \($0)" } ?? "Version: latest (not specified in block)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        } else {
            // parsedBlock is nil => parse failed (missing --url or --token). Keep it gentle.
            Label("Couldn't find a --url and --token yet. Paste the full block.", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundColor(.orange)
        }
    }

    // MARK: - Shared field

    /// A reusable "Install root" field. The directory is a *parent*; the installer creates a fresh
    /// subdirectory inside it for the new runner.
    private func installRootField(text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            TextField("Install root", text: text)
                .textFieldStyle(.roundedBorder)
            Text("A fresh runner directory is created inside this folder. Defaults to your configured install root.")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Derived state

    /// Best-effort parse of the pasted block for the live preview / runner-group visibility.
    /// `BlockParser.parse` throws on missing url/token; we treat a throw as "not parseable yet".
    private var parsedBlock: ParsedRunnerBlock? {
        try? BlockParser.parse(pastedBlock)
    }

    /// Whether the Create button is enabled for the active tab.
    private var canCreateCurrentTab: Bool {
        switch selectedTab {
        case .storedPAT:
            // Need a PAT, an owner, and (for repo scope) a repo.
            guard hasPAT else { return false }
            let trimmedOwner = owner.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedOwner.isEmpty else { return false }
            if !isOrg {
                let trimmedRepo = repo.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedRepo.isEmpty else { return false }
            }
            return !currentInstallRoot.isEmpty
        case .pasteBlock:
            // Need a parseable block (url + token present).
            return parsedBlock != nil && !currentInstallRoot.isEmpty
        }
    }

    /// The trimmed install-root string for the active tab.
    private var currentInstallRoot: String {
        let raw = (selectedTab == .storedPAT ? patInstallRoot : blockInstallRoot)
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Actions

    /// Kick off the create flow for the currently selected tab. Dismiss the sheet on success.
    private func createCurrentTab() {
        guard !isCreating else { return }

        // Resolve the install root (expand a leading ~) for the active tab.
        let installRoot = AppPaths.expandTilde(currentInstallRoot)

        // Capture the current banner id so we can tell whether AppState posted a NEW banner after
        // the flow finishes — a `.success` banner means we should dismiss, `.error` keeps us open.
        let priorBannerID = appState.banner?.id

        isCreating = true
        Task {
            switch selectedTab {
            case .storedPAT:
                await appState.createRunnerWithPAT(
                    owner: owner,
                    repo: repo,
                    isOrg: isOrg,
                    name: nonEmpty(patName),
                    labels: nonEmpty(patLabels),
                    // AppState already suppresses --runnergroup for non-org scopes; only send it for org.
                    runnerGroup: isOrg ? nonEmpty(patRunnerGroup) : nil,
                    installRoot: installRoot
                )
            case .pasteBlock:
                await appState.createRunnerFromBlock(
                    pastedBlock,
                    name: nonEmpty(blockName),
                    labels: nonEmpty(blockLabels),
                    runnerGroup: nonEmpty(blockRunnerGroup),
                    installRoot: installRoot
                )
            }

            // Back on the main actor (this Task is created from a @MainActor view). Decide outcome
            // from the banner AppState posted: a fresh success banner => dismiss the sheet.
            isCreating = false
            if let banner = appState.banner,
               banner.id != priorBannerID,
               banner.kind == .success {
                dismiss()
            }
        }
    }

    /// Trim a string and return nil if it is empty after trimming, so we only pass optional fields
    /// (name/labels/group) to `AppState` when the user actually provided one.
    private func nonEmpty(_ s: String) -> String? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
