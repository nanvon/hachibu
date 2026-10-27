# 界面图

README 里的界面图都由渲染测试生成，不是真机截图。`ImageRenderer` 画不出系统材质和 `NavigationSplitView`：面板的玻璃底板用壁纸上的半透明纯色近似；主窗口的外框、侧栏和工具栏是测试里画的静态图形，页面内容是 App 的 SwiftUI 视图；开关、步进器等系统控件换成了静态图形。

| 内容 | 中文文件 | 英文文件 | 来源 |
| --- | --- | --- | --- |
| 菜单栏面板，浅色和深色并排 | `zh-Hans/panel-light.png`、`zh-Hans/panel-dark.png` | `en/panel-light.png`、`en/panel-dark.png` | `PanelRenderTests`，示例数据 |
| 主窗口历史页，浅色 | `zh-Hans/history.png` | `en/history.png` | `ReadmeScreenshotTests`，本机历史数据库 |
| 主窗口通知页，浅色 | `zh-Hans/notifications.png` | `en/notifications.png` | 同上 |
| 主窗口设置页，浅色 | `zh-Hans/settings.png` | `en/settings.png` | 同上 |

只有面板放浅色和深色两张，其他页面只放浅色。README 里图片居中，说明写在图片下面。

## 面板

```bash
HACHIBU_RENDER_DIR=<临时目录> swift test --package-path Packages/HachibuKit --filter PanelRenderTests
```

`panel-detail-light.png`、`panel-detail-dark.png` 复制为 `zh-Hans/panel-light.png`、`zh-Hans/panel-dark.png`，带 `-en` 后缀的两张复制到 `en/`。面板读数是测试里的示例数据（插电、已达到充电上限 80%），与真机读数一致。

## 主窗口

主窗口三页读取本机历史数据库的副本，曲线、导入记录和温度都是真实记录；缺失读数和未记录的时段如实显示，不填造数据。电池状态（插电、上限 80%）和设置项（默认值）是测试里给定的。

页面里的日期和时长按进程的地区格式化，`swift test` 无法传入地区，所以直接运行测试助手，用 `-AppleLocale` 指定地区：`zh_CN` 出中文图，`en_US` 出英文图（文件名带 `-en`）。先编译测试：

```bash
swift build --package-path Packages/HachibuKit --build-tests
```

然后分别用 `zh_CN`、`en_US` 运行：

```bash
DEV=/Applications/Xcode.app/Contents/Developer
TESTS=$PWD/Packages/HachibuKit/.build/debug/FeatureUITests.xctest/Contents/MacOS/FeatureUITests
DYLD_FRAMEWORK_PATH=$DEV/Platforms/MacOSX.platform/Developer/Library/Frameworks \
DYLD_LIBRARY_PATH=$DEV/Platforms/MacOSX.platform/Developer/usr/lib \
HACHIBU_RENDER_DIR=<临时目录> \
HACHIBU_RENDER_DB="$HOME/Library/Application Support/io.github.nanvon.hachibu/history.sqlite" \
$DEV/Toolchains/XcodeDefault.xctoolchain/usr/libexec/swift/pm/swiftpm-testing-helper \
  --test-bundle-path "$TESTS" --testing-library swift-testing --filter ReadmeScreenshotTests -AppleLocale zh_CN
```

`history.png`、`notifications.png`、`settings.png` 复制到 `zh-Hans/`，带 `-en` 后缀的三张去掉后缀复制到 `en/`。出图后检查画面里没有个人信息。

## 真机截图

以后换成真机截图时：

- 使用正式构建、已接入品牌资源的应用。
- 保留真实数据和实际记录区间；缺失读数或尚无历史时如实展示，不填造曲线。
- 裁剪到应用窗口或面板，避免带入其他应用及个人信息。
- 中英文各一套，文件名沿用上表。
