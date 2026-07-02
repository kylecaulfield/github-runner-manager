import SwiftUI
import AppKit

/// The top-level content of the `MenuBarExtra` window.
///
/// Layout (fixed-size popover; a plain HStack, NOT NavigationSplitView — see body):
///   ┌──────────────────────────────────────────────┐
///   │ BannerView (only when appState.banner != nil) │
///   ├──────────────────────────────────────────────┤
///   │ controlStrip: Refresh · New · Update All* · ⚙ · Quit │
///   ├───────────────┬──────────────────────────────┤
///   │ RunnerListView│  RunnerDetailView / placeholder│
///   └───────────────┴──────────────────────────────┘
///
/// `RootView` owns the selected-runner id plus the search/sort UI state. Launch-time discovery
/// and polling are owned by `AppDelegate` (`appState.onAppear()` at launch); this view only
/// refreshes on open via `.task`. All heavy work happens inside `AppState`/services (off-main by
/// construction); this view only kicks off async work and reads published state, so it never
/// blocks the main thread.
struct RootView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var settings: AppSettings

    /// Opens auxiliary windows (the "New Runner" window scene) from within the popover.
    @Environment(\.openWindow) private var openWindow

    /// The currently selected runner id (== install path). Drives the detail pane.
    @State private var selection: Runner.ID?

    /// Free-text filter matched (case-insensitively) against runner name and scope.
    @State private var searchText = ""

    /// The order the runner list is sorted in.
    @State private var sortOrder: RunnerSort = .status

    var body: some View {
        VStack(spacing: 0) {
            // Top banner for errors / info / success. Dismiss clears AppState.banner.
            if let banner = appState.banner {
                BannerView(message: banner) {
                    appState.banner = nil
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            // Primary controls. NOTE: a `MenuBarExtra(.window)` panel is a borderless popover with
            // no title bar, so SwiftUI has nowhere to place `.toolbar` items — they would silently
            // vanish. We therefore render the actions as an explicit control strip in the body.
            controlStrip
            Divider()

            // At-a-glance counts + when we last refreshed.
            summaryHeader
            Divider()

            // Search + sort controls for the runner list.
            filterBar
            Divider()

            // Two-pane layout (list | detail). We deliberately AVOID NavigationSplitView here:
            // inside a MenuBarExtra(.window) popover it mis-renders its sidebar (the list can come
            // up empty, looking like "no runners") and its sizing fights the popover — which also
            // swallowed clicks on the control strip above. A plain HStack is reliable in a popover.
            HStack(spacing: 0) {
                // RootView owns filtering/sorting; the list just renders what it's given.
                RunnerListView(runners: filteredRunners, selection: $selection)
                    .frame(width: 250)
                Divider()
                detailPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // Give the popover a deterministic size (a MenuBarExtra window sizes to its content).
        .frame(width: 780, height: 520)
        .animation(.default, value: appState.banner)
        // Refresh whenever the popover opens. Launch-time discovery + polling are owned by
        // AppDelegate; refreshAll is @MainActor async and re-entrancy-guarded, so this is safe.
        .task {
            await appState.refreshAll()
        }
    }

    // MARK: - Detail pane

    /// The trailing pane: the selected runner's detail view, or a placeholder when nothing is
    /// selected (or the selection became stale after a refresh removed that runner).
    @ViewBuilder
    private var detailPane: some View {
        if let selectedRunner {
            // Key the detail view by id so it rebuilds cleanly when the selection changes.
            RunnerDetailView(runner: selectedRunner)
                .id(selectedRunner.id)
        } else {
            detailPlaceholder
        }
    }

    /// Resolve the selected id to a live `Runner` from `AppState` (the source of truth), so the
    /// detail view always reflects the latest enriched status/version/labels — and so a selection
    /// that no longer exists (e.g. a removed runner) cleanly falls back to the placeholder.
    private var selectedRunner: Runner? {
        guard let selection else { return nil }
        return appState.runners.first { $0.id == selection }
    }

    private var detailPlaceholder: some View {
        VStack(spacing: 10) {
            Image(systemName: "sidebar.left")
                .font(.system(size: 30))
                .foregroundColor(.secondary)
                .accessibilityHidden(true)
            Text("Select a runner")
                .font(.headline)
            Text("Choose a runner on the left to see its status, version, labels, and logs.")
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Summary header

    /// A compact status line: running / stopped / update counts, plus when we last refreshed.
    private var summaryHeader: some View {
        HStack(spacing: 14) {
            summaryChip(count: runningCount, label: "running", systemImage: "play.circle.fill", color: .green)
            summaryChip(count: stoppedCount, label: "stopped", systemImage: "stop.circle.fill", color: .orange)
            summaryChip(count: updateCount, label: "updates", systemImage: "arrow.down.circle.fill", color: .accentColor)

            Spacer(minLength: 8)

            if let last = appState.lastRefreshed {
                Text("Last refreshed \(last.formatted(.relative(presentation: .named)))")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .help("Last successful refresh: \(last.formatted(date: .abbreviated, time: .standard))")
            } else {
                Text("Not refreshed yet")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    /// One count chip (e.g. "3 running") for the summary header.
    private func summaryChip(count: Int, label: String, systemImage: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .foregroundColor(color)
                .accessibilityHidden(true)
            Text("\(count) \(label)")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(count) \(label)")
    }

    private var runningCount: Int { appState.runners.filter { $0.status.isRunning }.count }
    private var stoppedCount: Int { appState.runners.filter { $0.status == .stopped }.count }
    private var updateCount: Int { appState.runners.filter { $0.updateAvailable }.count }

    // MARK: - Filter bar

    /// Search field + sort picker. A plain `TextField` (NOT `.searchable`, which requires a
    /// navigation container we deliberately avoid inside the popover).
    private var filterBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
                .accessibilityHidden(true)
            TextField("Filter runners", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 220)

            Spacer(minLength: 8)

            Picker("Sort", selection: $sortOrder) {
                ForEach(RunnerSort.allCases) { order in
                    Text(order.label).tag(order)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .help("Sort the runner list")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    /// The runners actually shown in the list: filtered by `searchText` (name/scope, case-
    /// insensitive) and ordered by `sortOrder`. RootView owns this so `RunnerListView` stays dumb.
    private var filteredRunners: [Runner] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let matched = query.isEmpty ? appState.runners : appState.runners.filter { runner in
            runner.name.lowercased().contains(query)
                || runner.scope.displayName.lowercased().contains(query)
        }
        return matched.sorted { lhs, rhs in
            switch sortOrder {
            case .status:
                let l = Self.statusRank(lhs.status), r = Self.statusRank(rhs.status)
                if l != r { return l < r }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            case .name:
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            case .repo:
                let cmp = lhs.scope.displayName.localizedCaseInsensitiveCompare(rhs.scope.displayName)
                if cmp != .orderedSame { return cmp == .orderedAscending }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        }
    }

    /// Ordering rank for `.status` sort: running first, then problems, then inert states.
    private static func statusRank(_ status: RunnerStatus) -> Int {
        switch status {
        case .running: return 0
        case .stopped: return 1
        case .error: return 2
        case .notInstalled: return 3
        case .unknown: return 4
        }
    }

    // MARK: - Control strip

    /// True when at least one discovered runner has a newer release available. Drives the
    /// visibility of the "Update All" button.
    private var anyUpdateAvailable: Bool {
        appState.runners.contains { $0.updateAvailable }
    }

    /// The app's primary actions, rendered as a horizontal control strip at the top of the window
    /// (a MenuBarExtra window has no toolbar area — see the note at the call site).
    private var controlStrip: some View {
        HStack(spacing: 8) {
            // Refresh: full rediscovery + enrichment. Shows a spinner while in flight and disables
            // the button so we don't stack refreshes.
            Button {
                Task { await appState.refreshAll() }
            } label: {
                if appState.isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
            .disabled(appState.isRefreshing)
            .keyboardShortcut("r")
            .help("Rescan for runners and refresh status, versions, and labels (⌘R)")

            // New Runner: opens the dedicated "New Runner" window (id "new-runner"). We activate
            // the app so the window comes forward from the menu-bar (accessory) context.
            Button {
                openWindow(id: "new-runner")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label("New Runner", systemImage: "plus")
            }
            .keyboardShortcut("n")
            .help("Add a new self-hosted runner (⌘N)")

            // Bulk actions: start every non-running runner / stop every running runner.
            Menu {
                Button {
                    Task { await appState.startAll() }
                } label: {
                    Label("Start All", systemImage: "play.fill")
                }
                Button {
                    Task { await appState.stopAll() }
                } label: {
                    Label("Stop All", systemImage: "stop.fill")
                }
            } label: {
                Label("Bulk", systemImage: "square.stack.3d.up")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Start or stop all runners at once")

            // Update All: only shown when something can be updated.
            if anyUpdateAvailable {
                Button {
                    Task { await appState.updateAll() }
                } label: {
                    Label("Update All", systemImage: "square.and.arrow.down.on.square")
                }
                .help("Update every runner that has a newer release available")
            }

            Spacer(minLength: 8)

            // Settings: open the standard Settings/Preferences window (the app provides a
            // `Settings { SettingsView() }` scene, so ⌘, also works).
            Button {
                openSettingsWindow()
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .help("Open RunnerManager settings")

            // Quit: terminate the app from the menu-bar window.
            Button {
                NSApp.terminate(nil)
            } label: {
                Label("Quit", systemImage: "power")
            }
            .help("Quit RunnerManager")
        }
        .labelStyle(.titleAndIcon)
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Open the app's Settings scene window.
    ///
    /// On macOS 13 there is no `SettingsLink` (that's macOS 14+), so we send the AppKit action
    /// that the `Settings { … }` scene installs. The selector was renamed across releases
    /// ("showSettingsWindow:" on Ventura+, "showPreferencesWindow:" on older systems), so we try
    /// the modern one first and fall back to the legacy one. We also activate the app so the
    /// window comes forward from the menu-bar context.
    private func openSettingsWindow() {
        NSApp.activate(ignoringOtherApps: true)
        // There's no SettingsLink on macOS 13, so we send the AppKit action the `Settings` scene
        // installs into the responder chain. The selector was renamed: macOS 14+ uses
        // "showSettingsWindow:", macOS 13 uses "showPreferencesWindow:". Gating on
        // `NSApp.responds(to:)` is WRONG here — NSApplication doesn't implement these directly;
        // they're handled further down the responder chain. `sendAction` returns false when nothing
        // handled it, so try the modern selector first and fall back to the legacy one.
        if !NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }
}

/// How the runner list is ordered. Backed by a `String` so it can be persisted later if desired.
enum RunnerSort: String, CaseIterable, Identifiable {
    case status
    case name
    case repo

    var id: String { rawValue }

    /// User-facing label for the sort picker.
    var label: String {
        switch self {
        case .status: return "Status"
        case .name: return "Name"
        case .repo: return "Repository"
        }
    }
}
