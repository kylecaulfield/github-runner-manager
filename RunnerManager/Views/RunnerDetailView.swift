import SwiftUI

/// The detail pane for a single selected runner.
///
/// Lays out, top to bottom:
///  - **Status**: the live service status (+ PID when running) and Start / Stop / Restart buttons,
///    all disabled while an action for this runner is in flight.
///  - **Version**: installed vs. latest version, with an Update button when an update is available.
///  - **Labels**: the server-side labels as chips, or a "requires PAT" notice when none are known.
///  - **Paths**: the install directory (selectable) with a reveal-in-Finder affordance.
///  - **Logs**: an embedded `LogTailView` for this runner.
///  - **Danger zone**: a Remove… action gated behind a `confirmationDialog`, with an opt-in
///    "also delete the install directory" toggle.
///
/// All mutating buttons call `AppState`'s async methods inside `Task { … }` so the main thread is
/// never blocked; the heavy work (Process/network/filesystem) runs off-main inside those services.
struct RunnerDetailView: View {
    /// The runner to show. The parent (`RootView`) looks this up from `appState.runners` by the
    /// list selection and passes the live value, so enrichment updates flow in via re-render.
    let runner: Runner

    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var settings: AppSettings

    // MARK: - Local UI state (Danger zone)

    /// Drives the Remove… confirmation dialog.
    @State private var showRemoveConfirm = false

    /// The user's opt-in to also delete the install directory when removing. Captured at the moment
    /// the dialog is presented (the confirmationDialog reads it on confirm).
    @State private var deleteDirectoryOnRemove = false

    // MARK: - Derived

    /// True while any action for this specific runner is in flight (disables its controls).
    private var isBusy: Bool {
        appState.busyRunnerIDs.contains(runner.id)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                Divider()
                statusSection
                Divider()
                versionSection
                Divider()
                labelsSection
                Divider()
                pathsSection
                Divider()
                logsSection
                Divider()
                dangerZoneSection
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // The dialog is attached once at the root of the detail view; it reads the toggle captured
        // before presentation. Re-presenting after a runner switch is fine because state is local.
        .confirmationDialog(
            "Remove “\(runner.name)”?",
            isPresented: $showRemoveConfirm,
            titleVisibility: .visible
        ) {
            Button(removeButtonTitle, role: .destructive) {
                let alsoDelete = deleteDirectoryOnRemove
                Task { await appState.remove(runner, deleteDirectory: alsoDelete) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(removeConfirmMessage)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            StatusDot(status: runner.status, diameter: 12)

            VStack(alignment: .leading, spacing: 2) {
                Text(runner.name)
                    .font(.title2.weight(.semibold))
                    .textSelection(.enabled)
                Text(runner.scope.displayName)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
            }

            Spacer()

            if isBusy {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    // MARK: - Status

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Status")

            LabeledRow("State") {
                HStack(spacing: 6) {
                    StatusDot(status: runner.status, diameter: 9)
                    Text(statusText)
                        .font(.callout)
                        .textSelection(.enabled)
                }
            }

            HStack(spacing: 8) {
                // Start is meaningful only when the runner is not already running.
                Button("Start") {
                    Task { await appState.start(runner) }
                }
                .disabled(isBusy || runner.status.isRunning)

                Button("Stop") {
                    Task { await appState.stop(runner) }
                }
                .disabled(isBusy || !runner.status.isRunning)

                Button("Restart") {
                    Task { await appState.restart(runner) }
                }
                .disabled(isBusy)
            }
            .padding(.top, 2)

            // Surface long-running progress (e.g. during an update) inline so the user sees activity.
            if isBusy, let progress = appState.progressText, !progress.isEmpty {
                Text(progress)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    /// Human-readable status, including the PID when the service reports one and the detail string
    /// for an error status.
    private var statusText: String {
        switch runner.status {
        case let .running(pid):
            if let pid {
                return "Running (PID \(pid))"
            }
            return "Running"
        case .stopped:
            return "Stopped"
        case .notInstalled:
            return "Not installed"
        case .unknown:
            return "Unknown"
        case let .error(detail):
            return detail.isEmpty ? "Error" : "Error: \(detail)"
        }
    }

    // MARK: - Version

    private var versionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Version")

            LabeledRow("Installed", value: runner.installedVersion ?? "Unknown")
            LabeledRow("Latest", value: runner.latestVersion ?? "Unknown")

            if runner.updateAvailable {
                HStack(spacing: 8) {
                    UpdateBadge()
                    Button("Update") {
                        Task { await appState.update(runner) }
                    }
                    .disabled(isBusy)
                }
                .padding(.top, 2)
            } else if runner.installedVersion != nil, runner.latestVersion != nil {
                // Both versions are known and equal-or-newer locally: nothing to do.
                Text("Up to date.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Labels

    private var labelsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Labels")

            if !runner.labels.isEmpty {
                // Labels are server-side only (read via the GitHub API). Render them as wrapping chips.
                WrapChips(labels: runner.labels)
            } else if KeychainStore.hasPAT() {
                // A PAT is set but we still have no labels: either the API call hasn't completed yet
                // or the PAT lacks Administration access for this scope.
                Text("No labels found. They appear after a refresh if your PAT can read this runner.")
                    .font(.callout)
                    .foregroundColor(.secondary)
            } else {
                // No PAT: labels live server-side and cannot be read without one.
                Text("Labels require a GitHub PAT. Add one in Settings to see this runner's labels.")
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Paths

    private var pathsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Paths")

            LabeledRow("Install") {
                HStack(spacing: 6) {
                    Text(runner.installPath.path)
                        .font(.callout)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button {
                        LogReader.revealInFinder(runner.installPath)
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .buttonStyle(.borderless)
                    .help("Reveal install directory in Finder")
                }
            }

            // Show the launchd plist path when known (useful for debugging service issues).
            if let plist = runner.servicePlistPath {
                LabeledRow("Service plist") {
                    HStack(spacing: 6) {
                        Text(plist.path)
                            .font(.callout)
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button {
                            LogReader.revealInFinder(plist)
                        } label: {
                            Image(systemName: "magnifyingglass")
                        }
                        .buttonStyle(.borderless)
                        .help("Reveal LaunchAgent plist in Finder")
                    }
                }
            }

            if let label = runner.serviceLabel {
                LabeledRow("Service label", value: label)
            }
        }
    }

    // MARK: - Logs

    private var logsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Logs")
            // LogTailView reads settings (tail lines + poll interval) from the environment, which is
            // already injected up the view tree, so we just hand it the runner.
            LogTailView(runner: runner)
        }
    }

    // MARK: - Danger zone

    private var dangerZoneSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Danger zone")

            // The "also delete install directory" choice lives here so the user can set it before
            // opening the confirmation dialog (and the dialog confirms exactly what's about to happen).
            Toggle("Also delete the install directory on remove", isOn: $deleteDirectoryOnRemove)
                .toggleStyle(.checkbox)
                .disabled(isBusy)

            Button(role: .destructive) {
                showRemoveConfirm = true
            } label: {
                Label("Remove…", systemImage: "trash")
            }
            .disabled(isBusy)

            Text("Stops the service, de-registers the runner from GitHub (using your PAT when available), and uninstalls the launchd service.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    /// Title shown on the destructive confirm button — reflects whether the directory is also deleted.
    private var removeButtonTitle: String {
        deleteDirectoryOnRemove ? "Remove and Delete Directory" : "Remove"
    }

    /// Explanatory message inside the confirmation dialog.
    private var removeConfirmMessage: String {
        if deleteDirectoryOnRemove {
            return "This stops and uninstalls the service, de-registers the runner from GitHub, and permanently deletes the install directory at \(runner.installPath.path). This cannot be undone."
        }
        return "This stops and uninstalls the service and de-registers the runner from GitHub. The install directory at \(runner.installPath.path) is kept."
    }

    // MARK: - Small helpers

    /// A consistent section header.
    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.headline)
    }
}

// MARK: - WrapChips

/// A simple wrapping flow of label chips. macOS 13 has no `Grid`-free flow layout primitive that
/// wraps by width without `Layout`, so we compute line breaks manually against the container width
/// captured via a `GeometryReader`-backed preference. This keeps chips on as many rows as needed.
private struct WrapChips: View {
    let labels: [String]

    /// The measured container width, used to decide when to wrap to a new row.
    @State private var containerWidth: CGFloat = 0

    var body: some View {
        // Measure the available width, then lay chips out into rows that fit within it.
        ZStack(alignment: .topLeading) {
            // Width probe: an invisible full-width view whose geometry we read.
            GeometryReader { proxy in
                Color.clear
                    .preference(key: WidthKey.self, value: proxy.size.width)
            }
            .frame(height: 0)

            rows
        }
        .onPreferenceChange(WidthKey.self) { width in
            containerWidth = width
        }
    }

    private var rows: some View {
        // Build rows greedily based on the measured width. Falls back to a single column-ish layout
        // (one chip per row visually wrapping) when width is still unknown (0) on first pass.
        let computed = Self.computeRows(labels: labels, maxWidth: containerWidth)
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(computed.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 6) {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, label in
                        Chip(text: label)
                    }
                }
            }
        }
    }

    /// Greedy row packing: estimate each chip's width from its text length and wrap when the row
    /// would exceed `maxWidth`. This is an approximation (we don't measure glyphs precisely), but
    /// it is stable and avoids the need for `Layout` (macOS 14+). When `maxWidth <= 0` we keep all
    /// chips in one row and let SwiftUI clip/expand naturally.
    private static func computeRows(labels: [String], maxWidth: CGFloat) -> [[String]] {
        guard maxWidth > 0 else { return labels.isEmpty ? [] : [labels] }

        var rows: [[String]] = []
        var current: [String] = []
        var currentWidth: CGFloat = 0
        let spacing: CGFloat = 6

        for label in labels {
            let estimated = estimatedChipWidth(for: label)
            let projected = current.isEmpty ? estimated : currentWidth + spacing + estimated
            if !current.isEmpty, projected > maxWidth {
                rows.append(current)
                current = [label]
                currentWidth = estimated
            } else {
                current.append(label)
                currentWidth = projected
            }
        }
        if !current.isEmpty { rows.append(current) }
        return rows
    }

    /// Estimate a chip's rendered width: ~7pt per character (caption font) plus horizontal padding
    /// and border. Generous enough to avoid overflow without over-wrapping.
    private static func estimatedChipWidth(for label: String) -> CGFloat {
        let perChar: CGFloat = 7
        let horizontalPadding: CGFloat = 16 // 8pt each side from Chip
        return CGFloat(label.count) * perChar + horizontalPadding
    }
}

/// Preference key carrying the measured container width up from the `GeometryReader` probe.
private struct WidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
