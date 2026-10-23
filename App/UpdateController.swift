import Foundation
import os
import Sparkle

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Hachibu", category: "Update")

/// Sparkle 2 自动更新。appcast 地址和 EdDSA 公钥在 Config/Base.xcconfig 里配置，经 Info.plist 传给 Sparkle。
/// 公钥为空（还没生成密钥）时不启动更新器，设置页不显示“检查更新”。
@MainActor
final class UpdateController {
    private let updaterController: SPUStandardUpdaterController?

    init() {
        let publicKey = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        if publicKey.isEmpty {
            logger.info("SUPublicEDKey is empty, updater disabled")
            updaterController = nil
        } else {
            updaterController = SPUStandardUpdaterController(
                startingUpdater: true,
                updaterDelegate: nil,
                userDriverDelegate: nil
            )
        }
    }

    var isAvailable: Bool {
        updaterController != nil
    }

    func checkForUpdates() {
        updaterController?.checkForUpdates(nil)
    }
}
