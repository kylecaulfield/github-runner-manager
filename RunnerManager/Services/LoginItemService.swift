import Foundation
import ServiceManagement // SMAppService is macOS 13+

/// Manages the app's "Launch at Login" state via `SMAppService` (macOS 13+).
///
/// Ad-hoc / unsigned builds may not persist the login item reliably; callers should
/// surface thrown errors to the user rather than assuming success.
enum LoginItemService {

    /// Whether the app is currently registered as a Login Item.
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// The raw registration status of the app's Login Item.
    static var status: SMAppService.Status { SMAppService.mainApp.status }

    /// Register/unregister the app as a Login Item. Throws on failure (surface to the user).
    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
