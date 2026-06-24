import SwiftUI

/// Application entry point.
///
/// RunnerManager is a menu-bar-only SwiftUI app (LSUIElement / agent). It exposes a single
/// `MenuBarExtra` with a `.window` style popover containing the full management UI, plus a
/// standard `Settings` scene so the system ⌘, shortcut works and opens the same settings UI.
///
/// State ownership: `AppSettings` and `AppState` are created here as `@StateObject` so they live
/// for the lifetime of the process. The SAME shared instances are injected into BOTH scenes'
/// environments — that way preferences edited in the Settings window are immediately reflected in
/// the menu-bar popover (and vice versa). `AppState` is constructed with the shared `AppSettings`.
@main
struct RunnerManagerApp: App {
    // Created once; owned by the App for the whole process lifetime.
    @StateObject private var settings: AppSettings
    @StateObject private var appState: AppState

    init() {
        // Build the shared settings first, then hand the SAME instance to AppState.
        // We assign through local constants so both @StateObject wrappers wrap the same objects.
        let settings = AppSettings()
        let appState = AppState(settings: settings)
        _settings = StateObject(wrappedValue: settings)
        _appState = StateObject(wrappedValue: appState)
    }

    var body: some Scene {
        // Menu bar extra: window style gives us a popover-like panel hosting the full RootView.
        MenuBarExtra {
            RootView()
                .environmentObject(appState)
                .environmentObject(settings)
        } label: {
            // Icon reflects aggregate health of all discovered runners.
            MenuBarLabel(health: appState.aggregateHealth)
        }
        .menuBarExtraStyle(.window)

        // Settings scene so ⌘, opens preferences. Shares the SAME state instances.
        Settings {
            SettingsView()
                .environmentObject(appState)
                .environmentObject(settings)
        }
    }
}
