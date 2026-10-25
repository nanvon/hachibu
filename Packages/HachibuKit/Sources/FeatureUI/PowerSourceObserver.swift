import Foundation
import IOKit.ps

/// 分别监听插拔电源和电量/剩余时间变化。回调在主线程 run loop 上执行。
final class PowerSourceObserver {
    private final class Handler: Sendable {
        let onChange: @MainActor () -> Void

        init(onChange: @escaping @MainActor () -> Void) {
            self.onChange = onChange
        }
    }

    /// run loop source 只持有 handler 的裸指针，由这里保持 handler 存活。
    private let handler: Handler
    private let runLoopSources: [CFRunLoopSource]

    init(onChange: @escaping @MainActor () -> Void) {
        let handler = Handler(onChange: onChange)
        self.handler = handler
        let callback: IOPowerSourceCallbackType = { context in
            guard let context else { return }
            let handler = Unmanaged<Handler>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { handler.onChange() }
        }
        let context = Unmanaged.passUnretained(handler).toOpaque()
        runLoopSources = [
            IOPSCreateLimitedPowerNotification(callback, context)?.takeRetainedValue(),
            IOPSNotificationCreateRunLoopSource(callback, context)?.takeRetainedValue(),
        ].compactMap { $0 }

        for runLoopSource in runLoopSources {
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
    }

    deinit {
        for runLoopSource in runLoopSources {
            CFRunLoopSourceInvalidate(runLoopSource)
        }
    }
}
