import SwiftUI
import AppKit

/// Application entry point.
///
/// RunnerManager is a menu-bar-only SwiftUI app (LSUIElement / agent). It exposes a single
/// `MenuBarExtra` with a `.window` style popover containing the full management UI, a standard
/// `Settings` scene so the system ⌘, shortcut works, and a dedicated `Window` that hosts the
/// "New Runner" flow (opened from the popover via `openWindow(id:)`).
///
/// State ownership: an `AppDelegate` owns the shared `AppSettings` and `AppState` for the whole
/// process lifetime. This fixes the "discovery/polling/health only start when the popover opens"
/// bug: `applicationDidFinishLaunching(_:)` calls `appState.onAppear()` at LAUNCH, so the
/// menu-bar health glyph and the poll loop are live even before the user opens the popover. The
/// SAME instances are injected into EVERY scene's environment (popover, Settings window, New
/// Runner window) so edits in one place are immediately reflected everywhere.
@main
struct RunnerManagerApp: App {
    // The delegate owns the shared state and runs launch-time work (initial refresh + polling).
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Menu bar extra: window style gives us a popover-like panel hosting the full RootView.
        MenuBarExtra {
            RootView()
                .environmentObject(appDelegate.appState)
                .environmentObject(appDelegate.settings)
        } label: {
            // Icon reflects aggregate health of all discovered runners. MenuBarLabel observes
            // AppState directly so the glyph updates the moment health changes (e.g. from polling).
            MenuBarLabel(appState: appDelegate.appState)
        }
        .menuBarExtraStyle(.window)

        // Dedicated window for the "New Runner" flow, opened from RootView via
        // `openWindow(id: "new-runner")`. The id MUST match that call site. Shares the same state.
        Window("New Runner", id: "new-runner") {
            NewRunnerView()
                .environmentObject(appDelegate.appState)
                .environmentObject(appDelegate.settings)
        }

        // Settings scene so ⌘, opens preferences. Shares the SAME state instances.
        Settings {
            SettingsView()
                .environmentObject(appDelegate.appState)
                .environmentObject(appDelegate.settings)
        }
    }
}

/// Owns the process-lifetime shared state and drives launch-time startup.
///
/// Created once by `@NSApplicationDelegateAdaptor`. Because SwiftUI holds the adaptor for the
/// life of the app, `settings`/`appState` live for the whole process — the same role the old
/// `@StateObject` wrappers played, but now available at `applicationDidFinishLaunching` so we can
/// begin discovery + polling + health at LAUNCH rather than on first popover open.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The shared settings, built first so it can be handed to `AppState`.
    let settings = AppSettings()

    /// The shared orchestrator. `lazy` so `settings` is fully initialized before it's used, and
    /// so every scene references this one instance.
    lazy var appState = AppState(settings: settings)

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Start the initial refresh + status polling immediately, so the menu-bar health icon is
        // accurate and runners are tracked without requiring the user to open the popover first.
        appState.onAppear()
    }
}
