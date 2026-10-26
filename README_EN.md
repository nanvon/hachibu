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
  <a href="https://github.com/nanvon/hachibu/releases/latest"><img alt="Release" src="https://img.shields.io/github/v/release/nanvon/hachibu?color=287DD0&labelColor=102C60"></a>
  <a href="https://github.com/nanvon/hachibu/releases"><img alt="Total Downloads" src="https://img.shields.io/github/downloads/nanvon/hachibu/total?color=287DD0&labelColor=102C60"></a>
  <a href="https://github.com/nanvon/hachibu/releases/latest"><img alt="Latest Downloads" src="https://img.shields.io/github/downloads/nanvon/hachibu/latest/total?label=latest%20downloads&color=287DD0&labelColor=102C60"></a>
  <a href="https://github.com/nanvon/hachibu/actions/workflows/ci.yml"><img alt="CI" src="https://img.shields.io/github/actions/workflow/status/nanvon/hachibu/ci.yml?branch=main&labelColor=102C60"></a>
</p>

<p align="center">
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

For a laptop that stays plugged in most of the time, keeping the charge around 80% slows down battery capacity loss. Hachibu takes its name and its approach from this Japanese saying. It records battery data and can also change the system charge limit (80%–100%).

## Features

### Menu Bar and Panel

- **Menu bar** — A battery icon in macOS or iOS style, optionally followed by battery level (%), system power (W), or battery temperature (°C). Click to open the panel.
- **Charging status** — Distinguishes On Battery, Charging, Fully Charged, Charge Limit Reached, Above Charge Limit, Plugged In Not Charging, and Plugged In Draining, with time remaining or time until full.
- **Power flow** — Input power, system power, and battery power across three nodes: charger, computer, and battery. The hardware refreshes these values about every 60 seconds.
- **Reading cards** — Battery level, battery temperature (marked "High" at the alert threshold), and system power.
- **System charge limit** — On macOS 26.4 and later, turn the system charge limit on or off and pick a level from 80% to 100% in the panel or in Settings → Battery Charging. This is the same setting as System Settings → Battery. It can't be changed while another charge control app is running. When the battery is above the limit, macOS runs on battery until it drops to the limit. Limits below 80%, holding the current level (running on the charger without charging), and forced discharge are not supported: on recent firmware, the SMC keys needed to pause charging can't be accessed even with administrator privileges.
- **Battery health** — Maximum capacity reported by macOS and health status, cycle count, and full charge capacity as a ratio of design capacity; battery power and Low Power Mode. While plugged in, shows the charger's name and input voltage and current.

### History

- **Recent charts** — Recorded every minute. Shows battery level and battery temperature for the last 48 hours, with plugged-in periods shaded.
- **Long-term charts** — Recorded once a day. Shows maximum capacity, full charge / design, full charge capacity, and cycle count for all recorded history.
- **History import** — Import daily full charge capacity, cycle count, and maximum capacity from a JSON file in the Hachibu import format, in Settings. Imported data stays on your Mac.

### Background and Alerts

- **Launch at login** — Off by default; turn it on in Settings → General. Keeps recording in the background without preventing the Mac from sleeping.
- **Notifications** — Alerts when battery temperature stays above a threshold for 3 minutes (40°C by default), or when maximum capacity drops below a threshold (80% by default). Both alerts and their thresholds are set on the Notifications page.
- **Diagnostics export** — Exports raw battery readings as JSON. Serial numbers, UUIDs, and other device identifiers are removed before export.
- **Languages** — English and Simplified Chinese.

## Installation

Requirements: macOS 14 Sonoma or later on Apple Silicon (M-series chips). Intel Macs are not supported.

1. Download `Hachibu.dmg` from the [Releases page](https://github.com/nanvon/hachibu/releases/latest).
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

Third-party charge control tools change charging behavior. When one is running, Hachibu shows the actual state under that tool's control, for example "Plugged In, Not Charging". On Macs without a built-in battery (such as Mac mini and Mac Studio), Hachibu only shows "No battery detected" and records nothing.

## Data and Privacy

All data is read and stored on your Mac. Hachibu accesses the following:

| Source | Access | Purpose |
| :--- | :---: | :--- |
| IOKit power sources (IOPowerSources) | Read-only | Battery level, charging state, time remaining, charger info |
| IORegistry nodes `AppleSmartBattery` and `AppleSmartBatteryPack` | Read-only | Voltage, current, power, temperature, capacity, cycle count |
| `system_profiler SPPowerDataType` | Read-only, run once an hour | Maximum capacity, health status |
| Private framework PowerUI | Read/write | Reads the system charge limit; writes only when you change the switch or level |
| `/Library/Preferences/com.apple.powerd.charging.plist` | Read-only | System charge limit when PowerUI is unavailable |
| `~/Library/Application Support/io.github.nanvon.hachibu/` | Read/write | History database `history.sqlite` |

- **How data is recorded** — Minute data is kept for 7 days and then rolled up into hourly data; daily data is kept permanently. Nothing is recorded while the Mac is asleep, so charts break at that gap.
- **No data upload** — No analytics or tracking code. Battery data is never sent to any server.
- **Update checks** — Once a day, the app fetches the update feed from GitHub Releases. No device information is sent.
- **App Sandbox disabled** — Reading the system files above and running `system_profiler` requires the sandbox to be off. Notification permission is used only for temperature and health alerts.
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

## License

Hachibu is licensed under the [GNU General Public License v3.0](LICENSE), version 3 only (GPL-3.0-only).
