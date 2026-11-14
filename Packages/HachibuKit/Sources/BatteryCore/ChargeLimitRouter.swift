import Foundation
import os

/// 按目标选择写入方式：80–100% 经 PowerUI，1–79% 经特权 helper。规则见 docs/v1技术设计.md 21.2。
/// 回到 80% 以上或关闭时，若有低上限或遗留恢复标记，先经 helper 释放，再用 PowerUI 写入目标；
/// helper 不可用时直接用 PowerUI 关闭再写入。跟随系统设置时只会出现 80–100%，行为与 `PowerUIChargeLimitWriter` 相同。
public struct RoutedChargeLimitWriter: ChargeLimitWriter {
    /// 已批准、可用的 helper；没有时返回 nil。
    public typealias HelperProvider = @Sendable () -> ChargeHelperClient?

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Hachibu", category: "ChargeControl")
    /// 经 helper 写入后等待 PowerUI 读回的时长。本机实测约 1 秒。
    private static let readbackTimeout: TimeInterval = 5
    /// 低于这个值的上限由 helper 写入。
    public static let powerUIMinimum = 80

    private let helper: HelperProvider

    /// PowerUI 写入方法不可用时为 nil。
    public init?(helper: @escaping HelperProvider) {
        guard PowerUIClient.canWrite else { return nil }
        self.helper = helper
    }

    public func write(_ change: ChargeLimitChange) throws {
        switch change {
        case .enable:
            try PowerUIClient.write(.enable)
        case .disable, .limit(100...):
            try releaseHelperOverride()
            if currentSetting() != .off { try PowerUIClient.write(.disable) }
        case .limit(let percent) where percent < Self.powerUIMinimum:
            guard ChargeHelper.limitRange.contains(percent) else {
                throw ChargeLimitWriteError(message: "Limit out of range: \(percent)")
            }
            guard let helper = helper() else { throw ChargeLimitWriteError(message: "Helper unavailable") }
            try helper.setLimit(percent)
            try waitForReadback("helper limit \(percent)") { $0 == .on(percent: percent) }
            Self.logger.info("Helper set limit \(percent, privacy: .public)")
        case .limit(let percent):
            try releaseHelperOverride()
            if currentSetting() == .off {
                try PowerUIClient.write(.enable)
            }
            if currentSetting() != .on(percent: percent) {
                try PowerUIClient.write(.limit(percent))
            }
        }
    }

    /// 外部改值后仍可能有恢复标记，先释放，再让调用方写入目标。
    private func releaseHelperOverride() throws {
        let current = currentSetting()
        let isBelowMinimum: Bool
        if case .on(let percent)? = current {
            isBelowMinimum = percent < Self.powerUIMinimum
        } else {
            isBelowMinimum = false
        }
        let hasMarker = FileManager.default.fileExists(atPath: ChargeHelperMarker.url.path)
        if let helper = helper(), isBelowMinimum || hasMarker {
            try helper.release()
            Self.logger.info("Helper released the charge limit override")
        } else if isBelowMinimum {
            // helper 已移除或未批准：PowerUI 的关闭同样能清掉登记。
            Self.logger.info("Releasing the charge limit without helper")
            try PowerUIClient.write(.disable)
        } else {
            return
        }
        try waitForReadback("release") { setting in
            switch setting {
            case .off?: true
            case .on(let percent)?: percent >= Self.powerUIMinimum
            default: false
            }
        }
    }

    private func currentSetting() -> ChargeLimitSetting? {
        ChargeLimitSetting.resolve(powerUI: PowerUIClient.readFresh(), archive: nil)
    }

    private func waitForReadback(_ label: String, until predicate: (ChargeLimitSetting?) -> Bool) throws {
        let deadline = Date().addingTimeInterval(Self.readbackTimeout)
        repeat {
            if predicate(currentSetting()) { return }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < deadline
        throw ChargeLimitWriteError(message: "PowerUI read back timed out after \(label)")
    }
}

extension PowerUIChargeLimitWriter {
    /// 不经缓存读取当前上限。helper 释放和恢复时使用。
    public static func currentSetting() -> ChargeLimitSetting? {
        ChargeLimitSetting.resolve(powerUI: PowerUIClient.readFresh(), archive: nil)
    }
}
