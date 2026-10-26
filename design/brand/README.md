# Hachibu 品牌素材

正式素材沿用已选定的靛蓝饭碗、蓝色饭面、单颗米粒和顶部留白。颜色、轮廓及字标集中在 `scripts/generate-brand-assets.swift` 中定义；SVG、PDF、PNG 和 ICNS 均从同一份几何数据导出，不包含嵌入的位图。这里的 SVG 可以在设计工具中编辑，修改后需同步生成脚本，避免后续导出覆盖修改。

## 配色与字体

| 用途 | 色值 |
| --- | --- |
| 靛蓝主体 | `#102C60` |
| 蓝色饭面 | `#287DD0` |
| 浅暖白底板 | `#FFFCF5` |
| 次要文字 | `#53647D` |
| 深色背景字标 | `#FFFFFF` |

字标采用 macOS 自带的 Avenir Next，中文宣传图采用苹方。所有导出的文字已转为矢量路径，不依赖接收者安装字体，也不随仓库分发字体文件。

## 文件与使用位置

| 素材 | 母版或公开导出 | 运行资源 / 使用方 |
| --- | --- | --- |
| 独立饭碗 | `design/brand/bowl-mark.svg`、`docs/assets/brand/mark.svg` / `.png` | 品牌展示 |
| 应用图标 | `design/brand/app-icon-master.svg`、`docs/assets/brand/app-icon.png` | `App/Resources/Assets.xcassets/AppIcon.appiconset` |
| 菜单栏模板 | `design/brand/menubar-template.svg` | `App/Resources/Assets.xcassets/MenuBarIcon.imageset`，代码已不使用 |
| 浅背景 Logo | `design/brand/logo-light.svg`、`docs/assets/brand/logo-light.svg` / `.png` | README；FeatureUI 的 BrandLogo 默认外观 |
| 深背景 Logo | `design/brand/logo-dark.svg`、`docs/assets/brand/logo-dark.svg` / `.png` | README；FeatureUI 的 BrandLogo 深色外观 |
| GitHub 分享图 / 英文横幅 | `docs/assets/promo/github-social-preview.svg` / `.png` | GitHub Social preview、README_EN.md |
| 中文横幅 | `docs/assets/promo/readme-banner-zh-Hans.svg` / `.png` | README.md |
| 安装资源 | `packaging/dmg/` | `scripts/package-dmg.sh` |
| 素材总览 | `docs/assets/brand/overview.png` | 设计核对，不是应用截图 |

`logo-light` 指用于浅色背景的深色字标，`logo-dark` 指用于深色背景的白色字标。品牌图形中的留白和米粒均为真正透明的负形。

## 导出

在仓库根目录执行（需要 macOS 和 Xcode Command Line Tools，无第三方依赖）：

```bash
swift scripts/generate-brand-assets.swift
```

脚本覆盖表中由它生成的资源，请先把设计修改同步进脚本。应用代码、README 正文、签名和本地配置不在导出范围内。增删资源后按仓库规则运行 `xcodegen generate`。

应用图标提供 macOS 16、32、128、256、512 pt 的 1× / 2× PNG。底板按 Apple 图标网格放在 1024 画布中央的 824 × 824 区域，四周各留 100，在 Finder 里和系统图标一样大。AppIcon 是 Finder、通知等位置共用的应用图标；`LSUIElement` 下默认不显示 Dock 图标，不需要另一份 Dock 专用图标。

菜单栏模板是 22 × 18 pt 的矢量 PDF，脚本仍会导出，但菜单栏现在显示 `App/BatteryIconDrawing.swift` 自绘的 macOS / iOS 电池图标（`docs/v1技术设计.md` 第 9 节），不使用这份模板，也不把品牌饭碗当作电量刻度。

FeatureUI 的 BrandLogo 放在包自己的资源集中，通过 `Bundle.module` 使用；AppIcon 和菜单栏资源属于 App 主包。宣传素材不打进应用。

## 发布前

- GitHub 分享 PNG 为 1280 × 640，应小于 1 MB。在 GitHub 仓库 Settings → Social preview 手动上传 `docs/assets/promo/github-social-preview.png`。提交图片不会自动设置社交封面。
- DMG 背景和坐标见 `packaging/dmg/README.md`。`scripts/package-dmg.sh` 只组合素材，签名由 `scripts/build.sh` 完成。
- 真实应用截图还没有制作，规范见 `docs/assets/screenshots/README.md`。README 不引用尚不存在的截图。
- 宣传文案只描述 v1 的电池监控，充电控制属于 v2。界面内的通用图标仍使用 SF Symbols，曲线和流向图仍由代码绘制。

## 检查范围

导出后检查 PNG 尺寸、透明通道、PDF 页尺寸、矢量路径、ICNS 解码和资源目录引用，并按 AGENTS.md 编译和运行包测试。这些检查不能代替真实菜单栏、通知或 Finder 的显示验收。

导出脚本用 CoreText 把文字转成路径。在受限环境（例如沙箱里无法访问字体缓存）运行时，个别字形可能导出不完整，导出后要看一遍宣传图里的文字。
