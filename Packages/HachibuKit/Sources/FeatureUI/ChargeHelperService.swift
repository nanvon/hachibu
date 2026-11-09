import AppKit
import BatteryCore
import Foundation
import Observation
import os
import ServiceManagement

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Hachibu", category: "ChargeControl")

/// 特权 helper 的注册状态。规则见 docs/v1技术设计.md 21.3。
public enum ChargeHelperState: Sendable, Equatable {
    /// 没有注册过。
    case notRegistered
    /// 已注册，等待用户在“登录项与扩展”里批准。
    case requiresApproval
    case enabled
    /// App 包里找不到 helper 或 plist，或系统返回了其他状态。
    case unavailable

    enum Action { case install, approve, remove }

    var action: Action {
        switch self {
        case .notRegistered, .unavailable: .install
        case .requiresApproval: .approve
        case .enabled: .remove
        }
    }
    var canInstall: Bool { action == .install }

    init(status: SMAppService.Status?) {
        switch status {
        case nil, .notRegistered?: self = .notRegistered
        case .requiresApproval?: self = .requiresApproval
        case .enabled?: self = .enabled
        default: self = .unavailable
        }
    }
}

/// 管理 helper 的注册、批准和移除。只在用到低于 80% 的上限或开始校准时注册。
@MainActor
@Observable
public final class ChargeHelperService {
    public static let shared = ChargeHelperService()

    public private(set) var state: ChargeHelperState = .notRegistered
    /// 注册或移除失败时的说明，只用于日志和诊断导出。
    public private(set) var lastError: String?
    /// 安装失败时显示在设置页；等待系统批准不算安装失败。
    private(set) var registrationError: String?

    /// 本机系统版本已验证可以写入低于 80% 的上限。
    public nonisolated static var isBelowThresholdSupported: Bool {
        ManualChargeLimitPreferences.isSchemaSupported
    }

    /// 可以经 helper 写入低于 80% 的上限。
    public var isReady: Bool {
        state == .enabled && Self.isBelowThresholdSupported
    }

    @ObservationIgnored private let service: SMAppService?
    /// 写入路由在后台线程读取，所以单独加锁保存。
    private nonisolated static let availability = Availability()

    /// `service` 为 nil 时（测试、渲染）始终未注册。
    public init(service: SMAppService? = SMAppService.daemon(plistName: ChargeHelper.daemonPlistName)) {
        self.service = service
        refresh()
    }

    /// 给写入路由用的 helper 客户端；未批准时为 nil。可以在任意线程调用。
    public nonisolated static func readyClient() -> ChargeHelperClient? {
        availability.client
    }

    public func refresh() {
        let newState = ChargeHelperState(status: service?.status)
        if newState != state {
            logger.info("Helper state \(String(describing: newState), privacy: .public)")
            state = newState
        }
        if state == .enabled || state == .requiresApproval { registrationError = nil }
        guard service != nil else { return }
        // 未验证的新系统版本仍允许读取和释放已安装的 helper，只禁止新写入。
        Self.availability.client = state == .enabled ? ChargeHelperClient() : nil
    }

    /// 注册 helper。需要批准时打开“登录项与扩展”。
    public func register() {
        guard let service else { return }
        registrationError = nil
        do {
            try service.register()
            lastError = nil
        } catch {
            lastError = String(describing: error)
            logger.error("Failed to register helper: \(String(describing: error), privacy: .public)")
        }
        refresh()
        if state.canInstall {
            registrationError = lastError ?? "SMAppService status: \(service.status.rawValue)"
        }
        if state == .requiresApproval { openLoginItems() }
    }

    public func openLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// 移除 helper。调用前要先释放并读回确认：`unregister()` 会直接终止 helper，不会替我们恢复。
    public func unregister() async {
        guard let service else { return }
        do {
            try await service.unregister()
            lastError = nil
        } catch {
            lastError = String(describing: error)
            logger.error("Failed to unregister helper: \(String(describing: error), privacy: .public)")
        }
        refresh()
    }

    /// 读取 helper 报告的状态，用于设置页和诊断导出。失败时为 nil。
    public func helperStatus() async -> ChargeHelperStatus? {
        guard let client = Self.readyClient() else { return nil }
        return await Task.detached { try? client.status() }.value
    }

    private final class Availability: @unchecked Sendable {
        private let lock = NSLock()
        private var value: ChargeHelperClient?

        var client: ChargeHelperClient? {
            get { lock.withLock { value } }
            set { lock.withLock { value = newValue } }
        }
    }
}
