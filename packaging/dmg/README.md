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

`settings.py` 将 dmgbuild 生成的 `.background.tiff`、`.VolumeIcon.icns` 和 `.DS_Store` 固定在远离安装内容的坐标，并将初始滚动位置设为 `(0, 0)`，避免 Finder 开启“显示隐藏文件”时把辅助文件自动排到标题上。这些文件仍然存在，滚动或重新整理图标后可能看到。

窗口默认大小为 660 × 440，并配置为隐藏工具栏、侧栏、标签栏和状态栏。这些是 Finder 的初始显示设置，无法保证在已有窗口或标签页中打开时覆盖用户的窗口状态；打包脚本不修改系统 Finder 偏好。

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

发布前需使用新打包的 DMG 在 Finder 中验收：正常打开时核对背景、图标和窗口布局；开启“显示隐藏文件”时核对辅助文件不遮挡安装内容；通过已有窗口或标签页打开时单独检查实际显示。配置检查不能代替 Finder 验收；签名及发布验收按项目发布流程执行。
