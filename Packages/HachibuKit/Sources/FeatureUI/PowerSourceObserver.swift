import Foundation
import IOKit.ps

/// IOPS 电源变化通知（`IOPSNotificationCreateRunLoopSource`）。回调在主线程 run loop 上执行。
final class PowerSourceObserver {
    private final class Handler: Sendable {
        let onChange: @MainActor () -> Void

        init(onChange: @escaping @MainActor () -> Void) {
            self.onChange = onChange
        }
    }

    /// run loop source 只持有 handler 的裸指针，由这里保持 handler 存活。
    private let handler: Handler
    private let runLoopSource: CFRunLoopSource?

    init(onChange: @escaping @MainActor () -> Void) {
        let handler = Handler(onChange: onChange)
        self.handler = handler
        runLoopSource = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let handler = Unmanaged<Handler>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { handler.onChange() }
        }, Unmanaged.passUnretained(handler).toOpaque())?.takeRetainedValue()

        if let runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
    }

    deinit {
        if let runLoopSource {
            CFRunLoopSourceInvalidate(runLoopSource)
        }
    }
}
