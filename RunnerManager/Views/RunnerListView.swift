import SwiftUI

/// The sidebar list of discovered runners.
///
/// Binds a `List` `selection` to the parent's selected runner id so the detail pane can follow
/// the selection. Each row is a `RunnerRowView`. When discovery has found nothing, an empty-state
/// placeholder explains where to look (Settings search paths) and how to add a runner.
///
/// The list itself performs no actions; it observes `AppState.runners` for content and forwards
/// selection to `RootView` via the `selection` binding.
struct RunnerListView: View {
    /// The id (== install path) of the currently selected runner, owned by `RootView`.
    /// Optional so "no selection" is representable (and so the detail pane can show a placeholder).
    @Binding var selection: Runner.ID?

    @EnvironmentObject private var appState: AppState

    var body: some View {
        Group {
            if appState.runners.isEmpty {
                emptyState
            } else {
                // `List(selection:)` over Identifiable rows: tag is each Runner's `id`.
                List(selection: $selection) {
                    ForEach(appState.runners) { runner in
                        RunnerRowView(runner: runner)
                            // Tag explicitly so selection binds to the runner id even though
                            // we iterate with ForEach inside the List.
                            .tag(runner.id)
                    }
                }
                // A plain sidebar list reads well in a NavigationSplitView's leading column.
                .listStyle(.sidebar)
            }
        }
        .frame(minWidth: 240)
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
                ForEach(appState.settings.searchPaths, id: \.self) { path in
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
