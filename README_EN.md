<h1 align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/assets/brand/logo-dark.svg">
    <img src="docs/assets/brand/logo-light.svg" alt="Hachibu" width="360">
  </picture>
</h1>

<p align="center">
  <b>Battery monitor for the macOS menu bar</b><br>
  See charge, power, and temperature, and track long-term changes in battery health, full charge capacity, and cycle count.
</p>

<p align="center">
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-287DD0?labelColor=102C60&logo=apple&logoColor=white">
  <img alt="Apple Silicon" src="https://img.shields.io/badge/Apple%20Silicon-only-287DD0?labelColor=102C60">
  <img alt="Swift 6" src="https://img.shields.io/badge/Swift-6-287DD0?labelColor=102C60&logo=swift&logoColor=white">
  <a href="https://github.com/nanvon/hachibu/releases/latest"><img alt="Release" src="https://img.shields.io/github/v/release/nanvon/hachibu?color=287DD0&labelColor=102C60"></a>
  <a href="https://github.com/nanvon/hachibu/releases"><img alt="Total Downloads" src="https://img.shields.io/github/downloads/nanvon/hachibu/total?color=287DD0&labelColor=102C60"></a>
  <a href="https://github.com/nanvon/hachibu/releases/latest"><img alt="Latest Downloads" src="https://img.shields.io/github/downloads/nanvon/hachibu/latest/total?label=latest%20downloads&color=287DD0&labelColor=102C60"></a>
  <a href="https://github.com/nanvon/hachibu/actions/workflows/ci.yml"><img alt="CI" src="https://img.shields.io/github/actions/workflow/status/nanvon/hachibu/ci.yml?branch=main&labelColor=102C60"></a>
  <img alt="GPL-3.0-only" src="https://img.shields.io/badge/license-GPL--3.0--only-287DD0?labelColor=102C60">
</p>

<p align="center">
  <a href="#features">Features</a> ·
  <a href="#installation">Installation</a> ·
  <a href="#data-and-privacy">Data and Privacy</a> ·
  <a href="#build-from-source">Build from Source</a> ·
  <a href="#roadmap">Roadmap</a> ·
  <a href="README.md">简体中文</a>
</p>

![Hachibu: Battery monitor for macOS](docs/assets/promo/github-social-preview.png)

<p align="center">
  <b>腹八分目</b><br>
  <sub>hara hachi bu · stop eating when you are 80% full</sub>
</p>

For a laptop that stays plugged in most of the time, keeping the charge around 80% slows down battery capacity loss. Hachibu takes its name and its approach from this Japanese saying. v1 handles monitoring and history; charge limit control is planned for v2.

> [!NOTE]
> Hachibu is under development and the first version has not been released yet. This page describes the features of v1.

## Features

### Menu Bar and Panel

- **Menu bar reading** — Shows battery level (%), system power (W), or battery temperature (°C), your choice. Click to open the panel.
- **Charging status** — Distinguishes On Battery, Charging, Fully Charged, Charge Limit Reached, Plugged In Not Charging, and Plugged In Draining, with time remaining. On macOS 26.4 and later, reads the charge limit set in System Settings.
- **Power flow** — Input power, system power, and battery power across three nodes: charger, computer, and battery. Values come straight from the hardware with no derived numbers. The hardware refreshes them about every 60 seconds, and the panel shows when they were last updated.
- **Battery details** — Maximum capacity reported by macOS and health status, full charge capacity as a ratio of design capacity, cycle count, temperature, voltage, current, and Low Power Mode. While plugged in, shows the charger's name, manufacturer, and rated wattage.

### History

- **Recent charts** — Battery level, system power, and temperature recorded every minute, viewable over 1 hour, 24 hours, or 7 days. Plugged-in periods are shaded.
- **Long-term charts** — Health, full charge capacity, and cycle count recorded once a day, viewable over 30 days, 1 year, or all time.

### Background and Alerts

- **Launch at login** — Keeps recording in the background without preventing the Mac from sleeping.
- **Notifications** — Alerts when battery temperature stays above a threshold for 3 minutes (40°C by default), or when maximum capacity drops below a threshold (80% by default). Both thresholds can be changed in Settings.
- **Diagnostics export** — Exports raw battery readings as JSON. Serial numbers, UUIDs, and other device identifiers are removed before export.
- **Languages** — English and Simplified Chinese.

## Installation

Requirements: macOS 14 Sonoma or later on Apple Silicon (M-series chips). Intel Macs are not supported.

1. Once the first version is released, download `Hachibu.dmg` from the [Releases page](https://github.com/nanvon/hachibu/releases/latest).
2. Open the DMG and drag `Hachibu.app` into the Applications folder.

After that, update from Settings → About → Check for Updates…. Updates are downloaded, installed, and relaunched automatically.

> [!NOTE]
> **If macOS blocks the first launch**
>
> Release builds are ad-hoc signed and not notarized by Apple.
> 1. Open System Settings → Privacy & Security, find the message about Hachibu, and click "Open Anyway".
> 2. If macOS says the app is damaged, run this in Terminal:
>    ```bash
>    xattr -dr com.apple.quarantine /Applications/Hachibu.app
>    ```

Charge control tools such as AlDente change charging behavior. When one is running, Hachibu shows the actual state under that tool's control, for example "Plugged In, Not Charging". On Macs without a built-in battery (such as Mac mini and Mac Studio), Hachibu only shows "No battery detected" and records nothing.

## Data and Privacy

All data is read and stored on your Mac. Hachibu accesses the following:

| Source | Access | Purpose |
| :--- | :---: | :--- |
| IOKit power sources (IOPowerSources) | Read-only | Battery level, charging state, time remaining, charger info |
| IORegistry nodes `AppleSmartBattery` and `AppleSmartBatteryPack` | Read-only | Voltage, current, power, temperature, capacity, cycle count |
| `system_profiler SPPowerDataType` | Read-only, run once an hour | Maximum capacity, health status |
| `/Library/Preferences/com.apple.powerd.charging.plist` | Read-only | System charge limit |
| `~/Library/Application Support/io.github.nanvon.hachibu/` | Read/write | History database `history.sqlite` |

- **How data is recorded** — Minute data is kept for 7 days and then rolled up into hourly data; daily data is kept permanently. Metrics that cannot be read show "—" instead of 0. Nothing is filled in while the Mac is asleep; charts break at the gap.
- **No data upload** — No analytics or tracking code. Battery data is never sent to any server.
- **Update checks** — Once a day, the app fetches the update feed from GitHub Releases. No device information is sent.
- **App Sandbox disabled** — Reading the system files above and running `system_profiler` requires the sandbox to be off. Apart from disabling Library Validation so the update framework can load, the app requests no other entitlements; notification permission is used only for temperature and health alerts.
- **Clearing data** — Quit Hachibu and delete the Application Support folder listed above.

## Build from Source

Requires Xcode 26 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
brew install xcodegen
git clone https://github.com/nanvon/hachibu.git
cd hachibu
xcodegen generate
open Hachibu.xcodeproj
```

Select the `Hachibu` scheme in Xcode and run. The project signs locally by default (Sign to Run Locally), so no Apple Developer account is needed. To build from the command line:

```bash
xcodebuild -project Hachibu.xcodeproj -scheme Hachibu -configuration Debug build
```

`Hachibu.xcodeproj` is generated by XcodeGen from `project.yml` and is not committed. Run `xcodegen generate` again after editing `project.yml` or adding or removing files under `App/`.

<details>
<summary><b>Signing with your own certificate, packaging a release build</b></summary>

To sign with your own certificate, copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` and fill in your Team ID and signing identity. This file is listed in `.gitignore`.

To package a release build (output goes to `dist/`):

```bash
SPARKLE_PUBLIC_ED_KEY="update public key" ./scripts/build.sh
```

The script builds without signing, then ad-hoc signs each component and produces `dist/Hachibu.dmg` and `dist/Hachibu.app.zip`. Official releases are published by GitHub Actions when a tag is pushed; see [docs/打包发布.md](docs/打包发布.md) (Chinese).

</details>

## Roadmap

| Version | Scope |
| :--- | :--- |
| **v1** | Battery readings and history (the features described above) |
| **v2** | Charge control: set a charge limit, stop charging |
| **v3** | Import history from AlDente |

## License

Hachibu is licensed under the [GNU General Public License v3.0](LICENSE), version 3 only (GPL-3.0-only).
