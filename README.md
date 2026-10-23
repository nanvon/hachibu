<h1 align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/assets/brand/logo-dark.svg">
    <img src="docs/assets/brand/logo-light.svg" alt="Hachibu" width="360">
  </picture>
</h1>

<p align="center">
  <b>macOS 菜单栏电池监控工具</b><br>
  查看电量、功率和温度，记录电池健康度、满充容量和循环次数的长期变化。
</p>

<p align="center">
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-287DD0?labelColor=102C60&logo=apple&logoColor=white">
  <img alt="Apple Silicon" src="https://img.shields.io/badge/Apple%20Silicon-only-287DD0?labelColor=102C60">
  <img alt="Swift 6" src="https://img.shields.io/badge/Swift-6-287DD0?labelColor=102C60&logo=swift&logoColor=white">
  <img alt="GPL-3.0-only" src="https://img.shields.io/badge/license-GPL--3.0--only-287DD0?labelColor=102C60">
  <img alt="开发中" src="https://img.shields.io/badge/状态-开发中-287DD0?labelColor=102C60">
</p>

<p align="center">
  <a href="#功能">功能</a> ·
  <a href="#安装">安装</a> ·
  <a href="#数据与隐私">数据与隐私</a> ·
  <a href="#从源码构建">从源码构建</a> ·
  <a href="#路线图">路线图</a> ·
  <a href="README_EN.md">English</a>
</p>

![Hachibu：macOS 菜单栏电池监控](docs/assets/promo/readme-banner-zh-Hans.png)

<p align="center">
  <b>腹八分目</b><br>
  <sub>hara hachi bu · 吃到八分饱就停</sub>
</p>

长期接电使用的笔记本，把电量控制在 80% 左右可以减缓电池容量衰减。Hachibu 的名字和思路都来自这句日语。v1 负责监控和记录，充电上限控制计划在 v2 加入。

> [!NOTE]
> 项目正在开发，首个版本尚未发布。下文描述的是 v1 的功能。

## 功能

### 菜单栏与面板

- **菜单栏读数** — 显示电量（%）、系统功率（W）或电池温度（°C），三选一；点击打开面板。
- **充电状态** — 区分使用电池、充电中、已充满、已达到充电上限、已接电未充电、已接电但电量下降，并显示剩余时间。macOS 26.4 及以上会读取系统设置中的充电上限。
- **功率流向** — 充电器、电脑、电池三个节点间的输入功率、系统功率和电池功率。数值取自硬件读数，不做推算；硬件约每 60 秒刷新一次，面板标注更新时间。
- **电池详情** — 系统最大容量与健康状态、满充容量与设计容量之比、循环次数、温度、电压、电流、低电量模式；接电时显示充电器名称、厂商和额定功率。

### 历史记录

- **近期曲线** — 每分钟记录电量、系统功率、温度，可查看 1 小时、24 小时、7 天，接电时段以底色标出。
- **长期曲线** — 每天记录健康度、满充容量、循环次数，可查看 30 天、1 年或全部。

### 后台与提醒

- **登录时启动** — 后台持续记录，不阻止系统休眠。
- **通知** — 电池温度连续 3 分钟高于阈值（默认 40°C），或系统最大容量低于阈值（默认 80%）时提醒，阈值可在设置中修改。
- **诊断导出** — 将电池原始读数导出为 JSON，导出前移除序列号、UUID 等设备标识。
- **界面语言** — 英文、简体中文。

## 安装

运行环境：macOS 14 Sonoma 或更新版本，Apple Silicon（M 系列芯片），不支持 Intel Mac。

1. 首个版本发布后，从 [Releases 页面](https://github.com/nanvon/hachibu/releases/latest) 下载 `Hachibu.dmg`。
2. 打开 DMG，将 `Hachibu.app` 拖入「应用程序」文件夹。

之后在「设置 → 关于 → 检查更新…」中更新，下载后自动安装并重新启动。

> [!NOTE]
> **首次启动被系统拦截时**
>
> 发布的构建为 ad-hoc 签名，没有经过 Apple 公证。
> 1. 打开「系统设置 → 隐私与安全性」，找到 Hachibu 的拦截提示，点击「仍要打开」；
> 2. 若提示「应用程序已损坏」，在终端执行：
>    ```bash
>    xattr -dr com.apple.quarantine /Applications/Hachibu.app
>    ```

AlDente 等充电控制工具会改变充电行为。同时运行时，Hachibu 显示的是这些工具控制之后的实际状态，例如「已接电，未充电」。没有内置电池的 Mac（如 Mac mini、Mac Studio）只显示「未检测到电池」，不记录数据。

## 数据与隐私

所有数据都在本机读取和保存。Hachibu 访问的内容如下：

| 数据来源 | 访问方式 | 用途 |
| :--- | :---: | :--- |
| IOKit 电源信息（IOPowerSources） | 只读 | 电量、充电状态、剩余时间、充电器信息 |
| IORegistry 的 `AppleSmartBattery`、`AppleSmartBatteryPack` 节点 | 只读 | 电压、电流、功率、温度、容量、循环次数 |
| `system_profiler SPPowerDataType` | 只读，每小时运行一次 | 系统最大容量、健康状态 |
| `/Library/Preferences/com.apple.powerd.charging.plist` | 只读 | 系统充电上限 |
| `~/Library/Application Support/io.github.nanvon.hachibu/` | 读写 | 历史数据库 `history.sqlite` |

- **记录方式** — 分钟数据保留 7 天，之后汇总为小时数据；每日数据永久保存。读不到的指标显示「—」，不用 0 代替；休眠期间不补数据，曲线在缺口处断开。
- **不上传数据** — 不包含统计或追踪代码，不向任何服务器发送电池数据。
- **检查更新** — 每天访问一次 GitHub Releases 上的更新源，不附带设备信息。
- **未启用 App Sandbox** — 读取上表的系统文件和运行 `system_profiler` 需要关闭沙盒。除了为加载更新框架关闭 Library Validation，不申请其他权限；通知权限只用于温度和健康度提醒。
- **清除数据** — 退出 Hachibu 后删除上表中的 Application Support 目录。

## 从源码构建

需要 Xcode 26 或更新版本，以及 [XcodeGen](https://github.com/yonaskolb/XcodeGen)。

```bash
brew install xcodegen
git clone https://github.com/nanvon/hachibu.git
cd hachibu
xcodegen generate
open Hachibu.xcodeproj
```

在 Xcode 中选择 `Hachibu` scheme 运行。默认使用本地签名（Sign to Run Locally），不需要 Apple 开发者账号。命令行构建：

```bash
xcodebuild -project Hachibu.xcodeproj -scheme Hachibu -configuration Debug build
```

`Hachibu.xcodeproj` 由 XcodeGen 根据 `project.yml` 生成，不提交到仓库。修改 `project.yml` 或增删 `App/` 下的文件后，重新运行 `xcodegen generate`。

<details>
<summary><b>使用自己的证书签名、打包发布版</b></summary>

使用自己的证书签名：将 `Config/Local.xcconfig.example` 复制为 `Config/Local.xcconfig`，填入 Team ID 和签名身份。该文件已加入 `.gitignore`。

打包发布版（产物输出到 `dist/`）：

```bash
SPARKLE_PUBLIC_ED_KEY="更新公钥" ./scripts/build.sh
```

脚本不签名编译后逐层做 ad-hoc 签名，产出 `dist/Hachibu.dmg` 和 `dist/Hachibu.app.zip`。正式发布由 GitHub Actions 在推送 tag 后完成，见 [打包发布](docs/打包发布.md)。

</details>

## 路线图

| 版本 | 内容 |
| :--- | :--- |
| **v1** | 电池数据展示与历史记录（本文描述的功能） |
| **v2** | 充电控制：设定充电上限、停止充电 |
| **v3** | 导入 AlDente 的历史数据 |

## 许可证

本项目按 [GNU 通用公共许可证第 3 版](LICENSE)发布，仅限第 3 版（GPL-3.0-only）。
