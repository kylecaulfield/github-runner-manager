import Foundation
import UserNotifications

/// Best-effort local notifications via `UserNotifications`.
///
/// Every entry point degrades gracefully: authorization is requested lazily, delivery is
/// silently skipped when the user has not granted permission, and no code path can crash
/// (ad-hoc / unsigned signing may block delivery entirely — that is treated as a no-op).
enum NotificationService {

    /// Request authorization (alert + sound) if not yet determined. Returns whether
    /// notifications are currently allowed. Never throws.
    @discardableResult
    static func requestAuthorizationIfNeeded() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()

        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            return false
        case .notDetermined:
            // Ask once; treat any failure (e.g. ad-hoc signing) as "not allowed".
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            return granted
        @unknown default:
            return false
        }
    }

    /// Post a simple local notification (best-effort; silently no-ops if not authorized).
    static func post(title: String, body: String) {
        // Dispatch on a detached-from-caller Task so callers never block and any failure
        // (unauthorized, ad-hoc signing) is swallowed rather than surfaced.
        Task {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                break
            default:
                return // Not authorized: silently no-op.
            }

            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default

            // nil trigger → deliver immediately.
            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil)
            try? await center.add(request)
        }
    }
}
