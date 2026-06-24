import SwiftUI
import AppKit

/// The top-level content of the `MenuBarExtra` window.
///
/// Layout:
///   ┌──────────────────────────────────────────────┐
///   │ BannerView (only when appState.banner != nil) │
///   ├───────────────┬──────────────────────────────┤
///   │ RunnerListView│  RunnerDetailView / placeholder│   ← NavigationSplitView
///   └───────────────┴──────────────────────────────┘
///   toolbar: Refresh · New Runner (sheet) · Update All* · Settings · Quit
///
/// `RootView` owns the selected-runner id and the "new runner" sheet flag. It drives the app's
/// lifecycle by calling `appState.onAppear()` from `.task`. All heavy work happens inside
/// `AppState`/services (off-main by construction); this view only kicks off async work and reads
/// published state, so it never blocks the main thread.
struct RootView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var settings: AppSettings

    /// The currently selected runner id (== install path). Drives the detail pane.
    @State private var selection: Runner.ID?

    /// Whether the "New Runner" sheet is presented.
    @State private var showingNewRunner = false

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

            NavigationSplitView {
                RunnerListView(selection: $selection)
            } detail: {
                detailPane
            }
            // A reasonable minimum so the split view is usable in the popover-style window.
            .frame(minWidth: 720, minHeight: 460)
        }
        .animation(.default, value: appState.banner)
        // Kick off the initial refresh + polling exactly once when the window first appears.
        .task {
            appState.onAppear()
        }
        // The "New Runner" flow lives in a sheet so it can present its own TabView form.
        .sheet(isPresented: $showingNewRunner) {
            NewRunnerView()
                .environmentObject(appState)
                .environmentObject(settings)
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
            .help("Rescan for runners and refresh status, versions, and labels")

            // New Runner: opens the create sheet (PAT form or paste-block).
            Button {
                showingNewRunner = true
            } label: {
                Label("New Runner", systemImage: "plus")
            }
            .help("Add a new self-hosted runner")

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
        let showSettings = Selector(("showSettingsWindow:"))
        let showPreferences = Selector(("showPreferencesWindow:"))
        if NSApp.responds(to: showSettings) {
            NSApp.sendAction(showSettings, to: nil, from: nil)
        } else {
            // ASSUMPTION: on systems where the modern selector is unavailable, the legacy
            // preferences selector opens the same Settings scene.
            NSApp.sendAction(showPreferences, to: nil, from: nil)
        }
    }
}
