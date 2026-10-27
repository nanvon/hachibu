import Foundation
import os
import UserNotifications

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Hachibu", category: "Alerts")

/// 用 `UNUserNotificationCenter` 发送本地通知。需要在 App bundle 里创建，测试中不要使用。
/// 创建时把自己设为通知中心的 delegate（弱引用），调用方要持有它。
public final class SystemAlertNotifier: NSObject, AlertNotifier, UNUserNotificationCenterDelegate {
    override public init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    public func authorization() async -> NotificationAuthorization {
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .notDetermined: .notDetermined
        case .authorized, .provisional: .allowed
        default: .denied
        }
    }

    public func requestAuthorization() async -> NotificationAuthorization {
        do {
            try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        } catch {
            logger.error("Failed to request notification authorization: \(String(describing: error), privacy: .public)")
        }
        return await authorization()
    }

    /// 同类提醒用同一个标识符，新的替换通知中心里旧的那条。
    public func deliver(_ alert: BatteryAlert) async throws {
        let content = UNMutableNotificationContent()
        let identifier: String
        switch alert {
        case let .highTemperature(celsius, threshold):
            identifier = "highTemperature"
            content.title = String(localized: "Battery Temperature High", bundle: .module)
            content.body = String(
                localized: "The battery has stayed above \(threshold) °C for 3 minutes. Current temperature: \(DisplayFormat.celsius(celsius)).",
                bundle: .module
            )
        case .lowHealth:
            // 保留旧接口，但不再发送最大容量提醒。
            return
        }
        content.sound = .default

        try await UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        )
    }

    /// 主窗口在前台时也显示横幅。
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
