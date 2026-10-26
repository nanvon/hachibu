"""dmgbuild 设置：从统一布局读取，不运行 Finder / AppleScript。"""
import json
from pathlib import Path

assets = Path(defines["assets"]).resolve()
layout = json.loads((assets / "layout.json").read_text(encoding="utf-8"))
application = Path(defines["app"]).resolve()
if not application.is_dir() or application.name != layout["application"]["name"]:
    raise ValueError("需要已构建的 Hachibu.app")

format = "UDZO"
filesystem = "HFS+"
files = [str(application)]
symlinks = {"Applications": "/Applications"}
# 不用 hide_extensions：它在 App 根目录写入 com.apple.FinderInfo，
# 拷贝出去的 App 通不过 codesign --strict，Gatekeeper 可能判定为已损坏。
icon = str(assets / layout["volumeIcon"])
background = str(assets / layout["background"])
window_rect = ((120, 120), (layout["window"]["width"], layout["window"]["height"]))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
include_icon_view_settings = True
include_list_view_settings = False
arrange_by = None
scroll_position = (0, 0)
icon_size = layout["iconSize"]
text_size = 13
label_pos = "bottom"
icon_locations = {
    application.name: (layout["application"]["x"], layout["application"]["y"]),
    "Applications": (layout["applications"]["x"], layout["applications"]["y"]),
    # dmgbuild 1.6.7 将多分辨率背景和卷图标放在根目录。
    # 开启“显示隐藏文件”时也不要让辅助文件自动排列到安装说明上。
    ".background.tiff": (10000, 10000),
    ".VolumeIcon.icns": (10200, 10000),
    ".DS_Store": (10400, 10000),
}
