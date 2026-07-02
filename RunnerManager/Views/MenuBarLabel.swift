import SwiftUI

/// The menu-bar icon for RunnerManager's `MenuBarExtra`.
///
/// The icon is a single SF Symbol chosen from the app's aggregate health so a glance at the
/// menu bar conveys overall state. Per spec:
///   - `.allRunning`  -> "checkmark.circle.fill"      (everything up)
///   - `.someStopped` -> "exclamationmark.triangle.fill" (at least one not running)
///   - `.error`       -> "xmark.octagon.fill"         (at least one errored)
///   - `.empty`       -> "circle.dashed"              (no runners discovered)
///
/// We observe `AppState` directly (rather than being handed a snapshot value) so that when polling
/// republishes `runners`, the label's `body` re-runs and the glyph is invalidated immediately.
///
/// We render the symbol as a template image so it adopts the menu bar's appearance (light/dark,
/// active/inactive) automatically. A `MenuBarExtra` label is monochrome by design, so we rely on
/// the glyph shape — not color — to distinguish states.
struct MenuBarLabel: View {
    @ObservedObject var appState: AppState

    var body: some View {
        // Read aggregate health inside body so this View subscribes to AppState's publishes.
        let health = appState.aggregateHealth
        return Image(systemName: symbolName(for: health))
            // Template rendering lets the system tint the glyph to match the menu bar.
            .renderingMode(.template)
            .accessibilityLabel(Text(accessibilityLabel(for: health)))
            .help(accessibilityLabel(for: health))
    }

    /// The SF Symbol name for the given aggregate health.
    private func symbolName(for health: AggregateHealth) -> String {
        switch health {
        case .allRunning: return "checkmark.circle.fill"
        case .someStopped: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        case .empty: return "circle.dashed"
        }
    }

    /// Human-readable description used for the accessibility label and tooltip.
    private func accessibilityLabel(for health: AggregateHealth) -> String {
        switch health {
        case .allRunning: return "RunnerManager: all runners running"
        case .someStopped: return "RunnerManager: some runners stopped"
        case .error: return "RunnerManager: a runner reported an error"
        case .empty: return "RunnerManager: no runners found"
        }
    }
}
