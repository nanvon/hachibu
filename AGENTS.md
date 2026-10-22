# AGENTS.md

本文件为在本仓库中工作的 AI 编码助手提供项目指引。

## 项目现状

Hachibu 是 macOS 菜单栏电池监控应用，定位为 AlDente 的平替，准备开源并公开发布。名字来自“腹八分目”，对应只充到约 80% 的护电思路。目前只有工程骨架：菜单栏图标、空面板、空主窗口，还没有数据采集和存储代码。

文档：

- `docs/v1技术设计.md`：v1 写代码的依据，包括已定决策、数据来源、状态规则、存储结构。与其他文档冲突时以它为准。
- `docs/macOS菜单栏电池监控应用技术方案调研.md`：调研记录，只作背景参考。其中的防御性建议不要直接照做，以设计文档为准。

版本规划：

- v1：只做数据展示（本文件描述的范围）。
- v2：充电控制（需要写 SMC 和特权 helper，届时单独设计）。
- v3：导入 AlDente 的历史数据。

视觉设计稿（菜单栏面板 + 主窗口历史曲线，Liquid Glass 风格的 HTML 近似稿）暂未放入仓库。设计稿只用来参考布局和视觉，部分内容已过时：侧栏的“概览”页、“耗电量（系统负载）”标题、应用名“电池监控”、面板状态文字、流向图说明句和温度“正常 / 偏高”标签。这些以设计文档为准。

## v1 功能范围

- 菜单栏图标：可选显示电量、系统功率或温度；点击弹出面板。
- 面板：状态头部（电量、状态文字、剩余时间）、三节点功率流向图（充电器 / 电脑 / 电池，左列供电方、右列用电方，电池按方向换列）、电池健康、实时（温度、电压、电流）、充电器信息（仅插电时）、低电量模式、打开主窗口。
- 主窗口：历史曲线分两组，各自独立的时间范围。
  - 近期（每分钟采样）：电量、系统功率、温度；1 小时 / 24 小时 / 7 天；插电时段画底色。
  - 长期（每天一条）：健康度、满充容量、循环次数；30 天 / 1 年 / 全部；循环次数用阶梯线；早于首次记录的区间标“未记录”，横轴不缩短。
  - 另有通知页、设置页；首版不做概览页。
- 后台：登录启动，持续采样；分钟数据保留 7 天后聚合为小时数据，每日数据永久保存。

## 已定的技术方案

完整内容见 `docs/v1技术设计.md` 第 2–4 节，要点：

- 最低 macOS 14，只出 arm64，Swift 6 语言模式。
- 分发：Developer ID 签名 + 公证 + Hardened Runtime，不上 App Store，关闭 App Sandbox（需要读取系统 plist、运行 `system_profiler`，v2 还要访问 SMC）。
- 界面：AppKit 管应用外壳和所有窗口行为（`NSStatusItem` + `NSPanel([.borderless, .nonactivatingPanel])` + `NSWindowController`，`LSUIElement`）；窗口内容用 SwiftUI，经 `NSHostingView` 承载。SwiftUI 只写展示内容，窗口定位、关闭、焦点一律放在 AppKit 层。某个视图在 SwiftUI 里两次修不好就改用 AppKit 实现。
- 材质：macOS 26+ 用 `NSGlassEffectView`，更早系统用 `NSVisualEffectView`。
- 界面语言：英文和简体中文，文案用 String Catalog（`.xcstrings`），源语言为英文。界面文字不要硬编码在 `BatteryCore`、`HistoryStore` 里。
- 工程：XcodeGen（`project.yml`）生成 Xcode 工程，`.xcodeproj` 不提交；逻辑放在本地 Swift Package `HachibuKit`，分 `BatteryCore`、`HistoryStore`、`FeatureUI` 三个 target。
- 依赖：GRDB；Sparkle 2 在首次公开发布前接入。
- 仓库里不放密钥和证书。Team ID、签名身份放在不提交的 `Config/Local.xcconfig`，这样别人 clone 后不改工程就能用本地签名编译。

## 数据来源要点

在 MacBookPro18,1（M1 Pro）、macOS 27.0.1 上实测，完整字段表见设计文档第 5 节。

- 公开状态走 IOPowerSources（含变化通知）；扩展指标用 `IORegistryEntryCreateCFProperties` 一次读取 `AppleSmartBattery` 和 `AppleSmartBatteryPack` 两个节点。
- `PowerTelemetryData`：`SystemPowerIn` 输入功率、`SystemLoad` 系统功率、`BatteryPower` 电池功率（负数放电），单位 mW；`SystemVoltageIn` / `SystemCurrentIn` 单位 mV / mA。约每 60 秒刷新一次，和 `UpdateTime`（Unix 秒）同步变化，界面要标注更新时间。不要做配平计算。
- 温度在 `AppleSmartBatteryPack` 节点的 `BatteryData.Temperature`，除以 100 得 °C。`AppleSmartBattery` 主节点没有温度。v1 不读 SMC、不读 IOHID。
- 最大容量两个口径分开命名、分开存储：系统最大容量（`system_profiler`，本机 95%）和容量比 `FullChargeCapacity / DesignCapacity`（本机 91.4%）。
- 设计循环次数用 IORegistry 的 `DesignCycleCount9C`，不用 IOPS 的 `DesignCycleCount`（两者不一致）。
- 系统充电上限从私有文件 `/Library/Preferences/com.apple.powerd.charging.plist` 读取，格式不符就视为未知。`NotChargingReason` 不参与状态判断。
- 缺失的指标显示“—”，数据库存 `NULL`，不存 0；休眠期间保留数据缺口，不补数据。
- AlDente 等充电控制工具会改变充电行为，影响充电状态读数；测试充电相关逻辑前先退出这类工具。

## 常用命令

```bash
xcodegen generate                                   # 修改 project.yml 或增删 App/ 下的文件后重新生成工程
xcodebuild -project Hachibu.xcodeproj -scheme Hachibu -configuration Debug build
swift build --package-path Packages/HachibuKit      # 单独编译本地包
```

`Hachibu.xcodeproj` 由 XcodeGen 生成，不提交，不要手改。

## Git

主分支为 `main`。提交信息用 Conventional Commits 格式：类型前缀用英文（`feat`、`fix`、`docs`、`chore`、`refactor`、`test` 等，可加范围如 `feat(BatteryCore):`），描述和正文用中文。
