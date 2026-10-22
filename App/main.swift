import AppKit

// 不使用 nib：手动创建 delegate 并启动事件循环。
let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.run()
