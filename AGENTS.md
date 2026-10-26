# AGENTS.md

本文件为在本仓库中工作的 AI 编码助手提供项目指引。

## 项目现状

Hachibu 是 macOS 菜单栏电池监控应用，定位为 AlDente 的平替，准备开源并公开发布。名字来自“腹八分目”，对应只充到约 80% 的护电思路。v1 的功能（下文“v1 功能范围”）已经实现：数据采集、历史存储与聚合、菜单栏、面板、历史曲线、通知、设置、诊断导出、Sparkle 更新。发布流水线和 Sparkle 密钥已配置，v0.0.1 起由 GitHub Actions 发布。测试 fixture 目前只有“接电未充电”一种状态。

文档：

- `docs/v1技术设计.md`：v1 写代码的依据，包括已定决策、数据来源、状态规则、存储结构。与其他文档冲突时以它为准。其中第 19 节是界面视觉：原则、颜色含义、平台约束和改视觉的流程，不写像素值；实现状态和待办见 19.8，改完一项要更新 19.8。
- `design/brand/README.md`：品牌素材（应用图标、菜单栏图标、logo、宣传图、DMG 背景）的来源和导出方式，素材由 `scripts/generate-brand-assets.swift` 生成。
- `docs/打包发布.md`：`scripts/build.sh` 打包、GitHub Actions 发布、Sparkle 密钥配置。
- `release-notes/README.md`：每个版本更新说明的写法。
- `docs/macOS菜单栏电池监控应用技术方案调研.md`：调研记录，只作背景参考。其中的防御性建议不要直接照做，以设计文档为准。

版本规划：

- v1：只做数据展示（本文件描述的范围）。
- v2：充电控制。以控制系统原生充电上限（80%–100%）为主，经 PowerUI 写入；开关和档位已在面板和设置页实现（设计文档第 6 节），临时充满一次暂不做。低于 80%、航行模式等需要 SMC CHIE 和特权 helper，不进 v2。本机传统限充 SMC key 已不可用，见 `docs/v1技术设计.md` 第 18 节和 `docs/v2充电控制技术调研.md`。
- v3：导入 AlDente 的历史数据。只导入每日指标，不提供解密 AlDente 数据库的方法或指引，数据来源待定，见设计文档第 18 节。

旧的视觉设计稿（Liquid Glass 风格的 HTML 近似稿）已废弃，不作参考，按它定的像素规格也已从设计文档删除。现有面板和主窗口的样式不是定稿，正在重做。改界面样式按设计文档 19.1 的流程：先写渲染测试出图，自己看过再发给用户，用户确认后定稿；以确认过的渲染图和代码为准。

## v1 功能范围

- 菜单栏图标：可选显示电量、系统功率或温度；点击弹出面板。
- 面板（宽 360pt），从上到下：
  - 功率块：标题行为状态文字和“更新于 N 秒前”；下面是三段功率流向图（供电方 → MacBook → 用电方，充电器 / 电池在左，系统 / 电池在右，电池按方向换边），流带里有从左往右流动的光点，面板关闭或开启“减弱动态效果”时停止。
  - 三张读数卡片：电量（附剩余时间）、电池温度（达到温度提醒阈值时标“偏高”）、系统功率。
  - 系统充电上限：开关和档位（v2 功能，已实现）。
  - 电池健康：系统最大容量、满充容量、循环次数，标题行右侧为健康状态。
  - 详细数据（默认折叠）：电池电压、电流、功率，设计容量、容量比；插电时加上充电器名称和输入电压 · 电流。
  - 底部：低电量模式、打开主窗口、退出。
- 主窗口（默认 1200×840，最小 960×660）：历史曲线分两组，各自独立的时间范围，每行两张图。图上方显示读数，悬停时同组所有图一起换成悬停时刻的值和时间。
  - 近期（每分钟采样，7 天按小时平均）：电量、电池温度、系统功率、电池功率（充电为正、放电为负，分两色）、充电器输入功率、电池电压；1 小时 / 24 小时 / 7 天；插电时段画底色。
  - 长期（每天一条）：系统最大容量、容量比、满充容量、循环次数；30 天 / 1 年 / 全部；循环次数用阶梯线；早于首次记录的区间标“未记录”，横轴不缩短。
  - 另有通知页、设置页；首版不做概览页。
- 后台：登录启动（默认不开启，在设置页打开），持续采样；分钟数据保留 7 天后聚合为小时数据，每日数据永久保存。

## 已定的技术方案

完整内容见 `docs/v1技术设计.md` 第 2–4 节，要点：

- 最低 macOS 14，只出 arm64，Swift 6 语言模式。
- 分发：与 cc-bar 相同，ad-hoc 签名 + Hardened Runtime，不用付费开发者账号，不做公证；推送 tag 后由 GitHub Actions 发布到 GitHub Releases，appcast 作为 Release 附件。不上 App Store，关闭 App Sandbox（需要读取系统 plist、运行 `system_profiler`，v2 还要访问 SMC）。
- 界面：AppKit 管应用外壳和所有窗口行为（`NSStatusItem` + `NSPanel([.borderless, .nonactivatingPanel])` + `NSWindowController`，`LSUIElement`）；窗口内容用 SwiftUI，经 `NSHostingView` 承载。SwiftUI 只写展示内容，窗口定位、关闭、焦点一律放在 AppKit 层。某个视图在 SwiftUI 里两次修不好就改用 AppKit 实现。
- 材质：macOS 26+ 用 `NSGlassEffectView`，更早系统用 `NSVisualEffectView`。
- 界面语言：英文和简体中文，文案用 String Catalog（`.xcstrings`），源语言为英文。界面文字不要硬编码在 `BatteryCore`、`HistoryStore` 里。
- 工程：XcodeGen（`project.yml`）生成 Xcode 工程，`.xcodeproj` 不提交；逻辑放在本地 Swift Package `HachibuKit`，分 `BatteryCore`、`HistoryStore`、`FeatureUI` 三个 target。
- 依赖：GRDB（HachibuKit）；Sparkle 2（App target，`project.yml` 引入）。EdDSA 公钥未填写前不启用更新。
- 仓库里不放密钥和证书。Sparkle 私钥只放在本机钥匙串和 GitHub secret 里；公钥写在 `Config/Base.xcconfig`。想用自己证书编译时，Team ID、签名身份放在不提交的 `Config/Local.xcconfig`，别人 clone 后不改工程就能用本地签名编译。

## 数据来源要点

在 MacBookPro18,1（M1 Pro）、macOS 27.0.1 上实测，完整字段表见设计文档第 5 节。

- 公开状态走 IOPowerSources（含变化通知）；扩展指标用 `IORegistryEntryCreateCFProperties` 一次读取 `AppleSmartBattery` 和 `AppleSmartBatteryPack` 两个节点。
- `PowerTelemetryData`：`SystemPowerIn` 输入功率、`SystemLoad` 系统功率、`BatteryPower` 电池功率（负数放电），单位 mW；`SystemVoltageIn` / `SystemCurrentIn` 单位 mV / mA。约每 60 秒刷新一次，和 `UpdateTime`（Unix 秒）同步变化，界面要标注更新时间。不要做配平计算。
- 温度在 `AppleSmartBatteryPack` 节点的 `BatteryData.Temperature`，除以 100 得 °C。`AppleSmartBattery` 主节点没有温度。v1 不读 SMC、不读 IOHID。
- 最大容量两个口径分开命名、分开存储：系统最大容量（`system_profiler`，本机 95%）和容量比 `FullChargeCapacity / DesignCapacity`（本机 91.4%）。
- 设计循环次数用 IORegistry 的 `DesignCycleCount9C`，不用 IOPS 的 `DesignCycleCount`（两者不一致）。
- 系统充电上限优先用私有框架 PowerUI 读取（校验方法类型编码），不可用时退回读私有文件 `/Library/Preferences/com.apple.powerd.charging.plist`，格式不符就视为未知。写入只用 PowerUI 的 `setMCLLimit:error:`、`enableMCL:`、`disableMCL:`，同样校验类型编码，以 PowerUI 读回为准；不直接改 powerd 文件。规则见设计文档第 6 节。`NotChargingReason` 不参与状态判断。
- 缺失的指标显示“—”，数据库存 `NULL`，不存 0；休眠期间保留数据缺口，不补数据。
- AlDente 等充电控制工具会改变充电行为，影响充电状态读数；测试充电相关逻辑前先退出这类工具。

## 常用命令

```bash
xcodegen generate                                   # 修改 project.yml 或增删 App/ 下的文件后重新生成工程
xcodebuild -project Hachibu.xcodeproj -scheme Hachibu -configuration Debug build
swift build --package-path Packages/HachibuKit      # 单独编译本地包
```

`Hachibu.xcodeproj` 由 XcodeGen 生成，不提交，不要手改。

## 打包分发

打包的唯一入口是 `scripts/build.sh`，不要用 Xcode 的 Archive / Export 分发，也不要手动 `codesign`、`ditto` 拼流程：

```bash
SPARKLE_PUBLIC_ED_KEY="公钥" ./scripts/build.sh     # 产物：dist/Hachibu.dmg、dist/Hachibu.app.zip
```

- 脚本会先运行 `xcodegen generate`，再清空 `build/` 重新构建，用 `CODE_SIGNING_ALLOWED=NO` 做 Release 构建后逐层 ad-hoc 签名。
- 公钥缺失时脚本停止，避免分发无法验证更新的 App。密钥配置见 `docs/打包发布.md` 第 3 节，由维护者手动完成。
- 不要直接替换 `/Applications/Hachibu.app`，打包验证在 `dist/` 或临时目录里查看。
- 本地打包是耗时命令，只在用户要求时运行。

## 标准发布流程

用户说“发版”或明显同义的表述（“发布一下”“发个新版本”“提交代码、版本号 +1、打 tag 推送”）时，这是预先授权的固定指令，按下面四步顺序执行，不用逐步等确认：

1. **提交代码**：把工作区未提交的改动按仓库惯例提交，无关改动分开提交。没有改动就跳过。
2. **编写更新说明**：对比上一个 `v*` tag 与当前代码、提交和文档，按 `release-notes/README.md` 的撰写流程和自检问题，创建 `release-notes/vX.Y.Z.md`，并按同一文档“近期新功能”一节检查、更新 `release-notes/highlights.md`。
3. **版本号 +1**：修改 `Config/Base.xcconfig` 的 `MARKETING_VERSION`，patch 位 +1（如 `0.1.0` → `0.1.1`），除非用户明确要求升 minor / major。把版本号、本版更新说明和改动过的 `highlights.md` 一起单独提交，提交信息为 `chore: 发布 vX.Y.Z`。
4. **推送并打 tag**：
   ```bash
   git push origin main
   git tag vX.Y.Z
   git push origin vX.Y.Z
   ```

- tag 必须和已提交的 `MARKETING_VERSION` 一致；tag 只做标记，不改版本号。打错可撤销：`git tag -d vX.Y.Z && git push origin :vX.Y.Z`。
- 推送 tag 成功即完成，只汇报版本号、提交、Actions / Release 链接和本版更新说明全文。不主动查询、等待或轮询 CI 和 Release 状态，用户要求时才查。
- 首次发布用当前的 `MARKETING_VERSION`（`0.1.0`），不加 1。

## 改完代码后的校验

本节是对“未经要求不运行 build / test”的明确授权：每次改完代码，按改动范围运行下面的命令，不必再询问。

- 改了 `Packages/HachibuKit` 下的代码：
  `swift build --package-path Packages/HachibuKit --build-tests`
  `swift test --package-path Packages/HachibuKit`
- 改了 `App/`、`project.yml`、`Config/`，增删了文件，或改了 HachibuKit 的公共接口：
  `xcodegen generate`
  `xcodebuild -project Hachibu.xcodeproj -scheme Hachibu -configuration Debug build`
- 改了界面样式：另外运行对应的渲染测试出图并查看，例如
  `HACHIBU_RENDER_DIR=<临时目录> swift test --package-path Packages/HachibuKit --filter PowerFlowRenderTests`
- 只改文档时不运行。

项目代码出现编译警告也要处理，或者说明为什么不处理。GRDB 等依赖自身的警告不用管。校验失败要原样报告，不能跳过；修复如果超出原指令范围，先说明再改。只运行编译和测试，不启动 App，不做界面测试。

## Git

主分支为 `main`。提交信息用 Conventional Commits 格式：类型前缀用英文（`feat`、`fix`、`docs`、`chore`、`refactor`、`test` 等，可加范围如 `feat(BatteryCore):`），描述和正文用中文。
