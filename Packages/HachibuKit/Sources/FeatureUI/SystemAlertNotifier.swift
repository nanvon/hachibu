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
        case .calibrationCompleted:
            identifier = "calibrationCompleted"
            content.title = String(localized: "Battery Calibration Complete", bundle: .module)
            content.body = String(localized: "The charge limit is back to your setting.", bundle: .module)
        case let .calibrationPaused(reason):
            identifier = "calibrationPaused"
            content.title = String(localized: "Battery Calibration Paused", bundle: .module)
            switch reason {
            case .unplugged:
                content.body = String(localized: "Calibration paused. Plug in the power adapter to continue.", bundle: .module)
            case .appQuit:
                content.body = String(localized: "Calibration was not finished when Hachibu quit. Open Hachibu to continue or discard it.", bundle: .module)
            case .otherTool:
                content.body = String(localized: "Calibration paused because another charge control app is running.", bundle: .module)
            case .writeFailed:
                content.body = String(localized: "Calibration paused because the charge limit could not be changed. Hachibu will retry.", bundle: .module)
            case .helperUnavailable:
                content.body = String(localized: "Calibration paused. Allow Hachibu Helper in Settings to continue.", bundle: .module)
            case .user, .systemPolicy:
                return
            }
        case let .limitNotApplied(limit):
            identifier = "limitNotApplied"
            content.title = String(localized: "Charge Limit Not Applied", bundle: .module)
            content.body = String(localized: "Hachibu could not set the charge limit to \(limit)%. It will retry.", bundle: .module)
        case .systemCalibrationStarted:
            identifier = "systemCalibrationStarted"
            content.title = String(localized: "macOS Is Calibrating the Battery", bundle: .module)
            content.body = String(localized: "macOS is charging to 100% to calibrate the battery. Hachibu will return to your limit afterwards.", bundle: .module)
        case .chargeCompleted(let limit):
            identifier = "chargeCompleted"
            if let limit {
                content.title = String(localized: "Charge Limit Reached", bundle: .module)
                content.body = String(localized: "The battery has charged to your \(limit)% limit.", bundle: .module)
            } else {
                content.title = String(localized: "Battery Fully Charged", bundle: .module)
                content.body = String(localized: "You can unplug the power adapter.", bundle: .module)
            }
        case let .lowBattery(percent, threshold):
            identifier = "lowBattery"
            content.title = String(localized: "Low Battery", bundle: .module)
            content.body = String(
                localized: "Battery is at \(percent)%, at or below your \(threshold)% alert level. Plug in the power adapter.",
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
