<h1 align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/assets/brand/logo-dark.svg">
    <img src="docs/assets/brand/logo-light.svg" alt="Hachibu" width="360">
  </picture>
</h1>

<p align="center">
  <b>Battery monitor and charge limit tool for the macOS menu bar</b><br>
  See live power flow, charge, and temperature, track battery health, full charge capacity, and cycle count over time, and set the system charge limit (80%–100%).
</p>

<p align="center">
  <img alt="Platform" src="https://img.shields.io/badge/macOS-14%2B%20%C2%B7%20Apple%20Silicon-287DD0?logo=apple&logoColor=white&labelColor=102C60">
  <a href="https://github.com/nanvon/hachibu/releases/latest"><img alt="Release" src="https://img.shields.io/github/v/release/nanvon/hachibu?color=287DD0&labelColor=102C60"></a>
  <a href="https://github.com/nanvon/hachibu/releases"><img alt="Downloads" src="https://img.shields.io/github/downloads/nanvon/hachibu/total?color=287DD0&labelColor=102C60"></a>
  <a href="https://github.com/nanvon/hachibu/actions/workflows/ci.yml"><img alt="CI" src="https://img.shields.io/github/actions/workflow/status/nanvon/hachibu/ci.yml?branch=main&labelColor=102C60"></a>
  <a href="LICENSE"><img alt="License" src="https://img.shields.io/badge/license-GPL--3.0-287DD0?labelColor=102C60"></a>
</p>

<p align="center">
  <a href="https://github.com/nanvon/hachibu/releases/latest">Download</a> ·
  <a href="#features">Features</a> ·
  <a href="#installation">Installation</a> ·
  <a href="#data-and-privacy">Data and Privacy</a> ·
  <a href="#build-from-source">Build from Source</a> ·
  <a href="README.md">简体中文</a>
</p>

![Hachibu: Battery monitor for macOS](docs/assets/promo/github-social-preview.png)

<p align="center">
  <b>腹八分目</b><br>
  <sub>hara hachi bu · stop eating when you are 80% full</sub>
</p>

For a laptop that stays plugged in most of the time, keeping the charge around 80% slows down battery capacity loss. Hachibu takes its name and its approach from this Japanese saying: it records live battery readings and long-term health data, and can also change the system charge limit directly.

<p align="center">
  <img src="docs/assets/screenshots/en/panel-light.png" alt="Menu bar panel in light appearance" width="360">
  <img src="docs/assets/screenshots/en/panel-dark.png" alt="Menu bar panel in dark appearance" width="360">
  <br>
  <sub>Menu bar panel: power flow, battery level, temperature, system charge limit, and battery health (light on the left, dark on the right)</sub>
</p>

## Features

### Menu Bar and Panel

- **Menu bar** — A battery icon in macOS or iOS style, optionally followed by battery level (%), system power (W), or battery temperature (°C). Click to open the panel.
- **Charging status** — Distinguishes On Battery, Charging, Fully Charged, Charge Limit Reached, Above Charge Limit, Holding at the current level, Plugged In Not Charging, and Plugged In Draining, with time remaining or time until full.
- **Power flow** — Input power, system power, and battery power between the charger, the computer, and the battery. While the panel is open, the SMC is read every 2.5 seconds, and every second after you change the charge limit or plug in or unplug the charger. If the SMC can't be read, Hachibu falls back to IORegistry, which updates about every 60 seconds.
- **Reading cards** — Battery level, battery temperature (marked "High" at the alert threshold), and system power.
- **Battery health** — Maximum capacity reported by macOS and health status, cycle count, and full charge capacity as a ratio of design capacity. While plugged in, shows the charger's name and input voltage and current.
- **Low Power Mode** — Marked at the bottom of the panel when it's on. Regular apps can't switch Low Power Mode, so Hachibu only shows its state.

### System Charge Limit

Requires macOS 26.4 or later. This is the same setting as System Settings → Battery, and no privileged helper is installed.

- **Switch and level** — Turn the charge limit on or off and pick a level from 80% to 100% in the panel or in Settings → Battery Charging.
- **When above the limit** — By default, Discharge to Limit: macOS runs on battery until the charge drops to the limit. With Hold Current Charge, Hachibu temporarily sets the system limit to the current level (up to 99%), so the charger powers your Mac and the battery stops discharging. Your limit is restored when you unplug, switch back to the default, or quit Hachibu.
- **Other charge control apps** — The charge limit is not changed while another charge control app is running.

Limits below 80%, pausing charging while the battery is below the limit, and forced discharge are not supported: on recent firmware, the SMC keys needed to pause charging can't be accessed even with administrator privileges.

### History

Shown on the History page of the main window. Hover over a chart to see the readings at that moment.

<p align="center">
  <img src="docs/assets/screenshots/en/history.png" alt="History page of the main window">
  <br>
  <sub>History: battery health for all recorded history (including data imported from AlDente) at the top, the last 48 hours below; gaps are periods when the Mac was asleep or Hachibu wasn't running</sub>
</p>

- **Battery health** — Recorded once a day. Shows full charge capacity (daily values and a 14-day average), maximum capacity reported by macOS, and cycle count for all recorded history. After 60 days of records, it also summarizes how full charge capacity and cycle count have changed.
- **Last 48 hours** — Recorded every minute. Shows battery level and battery temperature, with plugged-in periods shaded and the alert threshold drawn when the temperature gets close to it. Below the charts: time plugged in, time charging, and time not recorded, plus the highest, average, and lowest temperature.
- **History import** — In Settings → History Data → Import History…, import daily full charge capacity, cycle count, and maximum capacity from a JSON file in the Hachibu import format. Imported data stays on your Mac.

### Background and Alerts

- **Launch at login** — Off by default; turn it on in Settings → General. Keeps recording in the background without preventing the Mac from sleeping.
- **Temperature alert** — Sends a notification when battery temperature stays above a threshold for 3 minutes (40°C by default), and can alert again after the temperature drops. Turn it on or off and set the threshold on the Notifications page.
- **Diagnostics export** — Exports raw battery readings as JSON. Serial numbers, UUIDs, and other device identifiers are removed before export.
- **Languages** — English and Simplified Chinese.

<p align="center">
  <img src="docs/assets/screenshots/en/notifications.png" alt="Notifications page of the main window">
  <br>
  <sub>Notifications: permission status, temperature alert threshold, current temperature, and the highest temperature in the last 48 hours</sub>
</p>

<p align="center">
  <img src="docs/assets/screenshots/en/settings.png" alt="Settings page of the main window">
  <br>
  <sub>Settings: system charge limit, menu bar, launch at login, and imported history</sub>
</p>

## Installation

Requirements: macOS 14 Sonoma or later on Apple Silicon (M-series chips). Intel Macs are not supported. Changing the charge limit requires macOS 26.4 or later.

1. Download `Hachibu.dmg` from the [Releases page](https://github.com/nanvon/hachibu/releases/latest).
2. Open the DMG and drag `Hachibu.app` into the Applications folder.

Hachibu checks for updates once a day and asks before installing a new version. You can also check manually in Settings → About → Check for Updates….

> [!NOTE]
> **If macOS blocks the first launch**
>
> Release builds are ad-hoc signed and not notarized by Apple.
> 1. Open System Settings → Privacy & Security, find the message about Hachibu, and click "Open Anyway".
> 2. If macOS says the app is damaged, run this in Terminal:
>    ```bash
>    xattr -dr com.apple.quarantine /Applications/Hachibu.app
>    ```

Third-party charge control tools change charging behavior. When one is running, Hachibu shows the actual state under that tool's control, for example "Plugged In, Not Charging". On Macs without a built-in battery (such as Mac mini and Mac Studio), Hachibu only shows "No battery detected" and records nothing.

## Data and Privacy

All data is read and stored on your Mac. Hachibu accesses the following:

| Source | Access | Purpose |
| :--- | :---: | :--- |
| IOKit power sources (IOPowerSources) | Read-only | Battery level, charging state, time remaining, charger info |
| IORegistry nodes `AppleSmartBattery` and `AppleSmartBatteryPack` | Read-only | Voltage, current, power, temperature, capacity, cycle count |
| SMC | Read-only, no write code | Live charging state, power, input voltage and current, and temperature |
| `system_profiler SPPowerDataType` | Read-only, run once an hour | Maximum capacity, health status |
| Private framework PowerUI | Read/write | Reads the system charge limit; writes when you change the switch or level, and when Hold Current Charge starts or ends |
| `/Library/Preferences/com.apple.powerd.charging.plist` | Read-only | System charge limit when PowerUI is unavailable |
| `~/Library/Application Support/io.github.nanvon.hachibu/` | Read/write | History database `history.sqlite` |

- **How data is recorded** — Minute data is kept for 7 days and then rolled up into hourly data; daily data is kept permanently. Nothing is recorded while the Mac is asleep, so charts break at that gap.
- **No data upload** — No analytics or tracking code. Battery data is never sent to any server.
- **Update checks** — Once a day, the app fetches the update feed from GitHub Releases. No device information is sent.
- **App Sandbox disabled** — Reading the system files above, running `system_profiler`, and calling PowerUI require the sandbox to be off. Notification permission is used only for temperature and health alerts.
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

To sign with your own certificate, copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` and fill in your Team ID and signing identity. This file is listed in `.gitignore`.

To package a DMG, use `scripts/build.sh`. It requires a Sparkle public key; see [docs/打包发布.md](docs/打包发布.md) (Chinese) for the process.

## License

Hachibu is licensed under the [GNU General Public License v3.0](LICENSE), version 3 only (GPL-3.0-only).
