# DMG 安装素材

| 文件 | 用途 |
| --- | --- |
| `background.svg` | 可编辑安装背景，660 × 440 |
| `background.png` | 1× PNG，660 × 440 |
| `background@2x.png` | 2× PNG，1320 × 880，144 DPI，对应 660 × 440 pt |
| `VolumeIcon.icns` | 从同一 AppIcon 导出的磁盘卷图标 |
| `layout.json` | 窗口大小、图标尺寸、应用与 Applications 的位置 |
| `settings.py` | dmgbuild 的无界面布局配置，从 layout.json 读取 |

背景不包含假的应用或文件夹图标，也不重复显示 Finder 已有的文件名。应用图标中心为 `(180, 236)`，Applications 中心为 `(480, 236)`，图标大小为 96 pt。

## 制作安装包

安装打包工具 [dmgbuild](https://dmgbuild.readthedocs.io/en/latest/)（仅用于发布制作，不是应用依赖）。在临时目录创建独立 Python 环境，避免修改系统 Python：

```bash
python3 -m venv /tmp/hachibu-dmg-tools
/tmp/hachibu-dmg-tools/bin/python -m pip install dmgbuild==1.6.7
export PATH="/tmp/hachibu-dmg-tools/bin:$PATH"
```

正式打包的唯一入口仍是 `scripts/build.sh`，在仓库根目录执行：

```bash
SPARKLE_PUBLIC_ED_KEY="公钥" ./scripts/build.sh
```

`build.sh` 完成构建与签名后，会调用内部的 `scripts/package-dmg.sh` 组合素材。内部脚本要求输出目录已存在、输出 DMG 尚不存在；它本身不覆盖文件、不签名、不公证、不上传。不要绕过项目发布入口手动拼装分发流程。

只检查打包命令、不创建磁盘、不操作 Finder：

```bash
bash scripts/package-dmg.sh --dry-run /absolute/path/to/Hachibu.app /absolute/path/to/Hachibu.dmg
```

`settings.py` 从 `layout.json` 读取背景、卷图标、窗口和图标参数。背景入口指向 1× PNG，dmgbuild 自动发现同目录的 `background@2x.png` 并合成多分辨率 TIFF。dmgbuild 直接写入磁盘布局，无需启动 Finder 或运行 AppleScript；真正打包时仍会通过系统工具创建、挂载和压缩磁盘镜像。`scripts/build.sh` 和 Release workflow 已接入同一入口，CI 在独立环境中安装锁定版本的 dmgbuild。

本次仅检查素材、布局配置和打包命令，不启动 App、不制作或发布安装包；签名及发布验收按项目发布流程执行。
