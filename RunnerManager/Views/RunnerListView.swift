import SwiftUI
import AppKit   // NSWorkspace / NSPasteboard for the per-row context menu actions

/// The list of discovered runners.
///
/// Binds a `List` `selection` to the parent's selected runner id so the detail pane can follow
/// the selection. Each row is a `RunnerRowView`. When there is nothing to show, an empty-state
/// placeholder explains where to look (Settings search paths) and how to add a runner.
///
/// The list itself performs no discovery or sorting: `RootView` now owns filtering/sorting and
/// passes the already-prepared `runners` in. The only actions it performs are the per-row
/// context-menu commands (start/stop/open/copy), which it forwards to `AppState`.
struct RunnerListView: View {
    /// The runners to display, already filtered and sorted by `RootView`.
    let runners: [Runner]

    /// The id (== install path) of the currently selected runner, owned by `RootView`.
    /// Optional so "no selection" is representable (and so the detail pane can show a placeholder).
    @Binding var selection: Runner.ID?

    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Group {
            if runners.isEmpty {
                emptyState
            } else {
                // `List(selection:)` over Identifiable rows: tag is each Runner's `id`.
                List(selection: $selection) {
                    ForEach(runners) { runner in
                        RunnerRowView(runner: runner)
                            // Tag explicitly so selection binds to the runner id even though
                            // we iterate with ForEach inside the List.
                            .tag(runner.id)
                            .contextMenu { contextMenu(for: runner) }
                    }
                }
                // An inset list reads well now that the list is a primary content column
                // (RootView composes it directly rather than as a sidebar).
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 240)
    }

    /// Per-row right-click actions. These are the list's only side effects; each start/stop
    /// hands off to `AppState` (which owns busy plumbing), while copy/open use AppKit directly.
    @ViewBuilder
    private func contextMenu(for runner: Runner) -> some View {
        Button("Start") { Task { await appState.start(runner) } }
        Button("Stop") { Task { await appState.stop(runner) } }

        Divider()

        if let url = runner.scope.runnersSettingsURL {
            Button("Open on GitHub") { NSWorkspace.shared.open(url) }
        }

        Divider()

        Button("Copy Install Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(runner.installPath.path, forType: .string)
        }
        Button("Copy Labels") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(runner.labels.joined(separator: ", "), forType: .string)
        }
        .disabled(runner.labels.isEmpty)
    }

    /// Shown when no runners were discovered. Guides the user to Settings / adding a runner.
    /// We do NOT trigger discovery here (RootView's toolbar Refresh and the poll loop own that);
    /// this is purely informational.
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 28))
                .foregroundColor(.secondary)
                .accessibilityHidden(true)

            Text("No runners found")
                .font(.headline)

            Text("Check your search paths in Settings, or add a new runner.")
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            // Diagnostic: show exactly which roots were scanned, so a runner that lives outside
            // these paths is immediately obvious (add its parent in Settings → Search Paths).
            VStack(alignment: .leading, spacing: 2) {
                Text("Searched roots")
                    .font(.caption.bold())
                    .foregroundColor(.secondary)
                ForEach(settings.searchPaths, id: \.self) { path in
                    Text(path)
                        .font(.caption.monospaced())
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(.top, 4)
        }
        .padding(24)
        .frame(minWidth: 240, maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}
