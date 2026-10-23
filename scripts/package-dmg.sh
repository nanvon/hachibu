#!/bin/bash
# build.sh 的内部打包步骤；不负责签名、公证或发布。
set -euo pipefail

usage() {
  echo "用法：bash scripts/package-dmg.sh [--dry-run] /path/to/Hachibu.app /path/to/Hachibu.dmg"
}

dry_run=false
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi
if [[ "${1:-}" == "--dry-run" ]]; then
  dry_run=true
  shift
fi
if [[ $# -ne 2 ]]; then
  usage >&2
  exit 1
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
layout="$repo_root/packaging/dmg/layout.json"
read_layout() { /usr/bin/plutil -extract "$1" raw -o - "$layout"; }

application="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
output_dir="$(cd "$(dirname "$2")" && pwd)"
output="$output_dir/$(basename "$2")"
app_name="$(read_layout application.name)"

if [[ ! -d "$application" || "$(basename "$application")" != "$app_name" ]]; then
  echo "需要有效的 $app_name 应用目录：$application" >&2
  exit 1
fi
if [[ "$output" != *.dmg || -e "$output" ]]; then
  echo "输出必须是尚不存在的 .dmg 文件：$output" >&2
  exit 1
fi

command=(dmgbuild -s "$repo_root/packaging/dmg/settings.py"
  -D "app=$application" -D "assets=$repo_root/packaging/dmg" Hachibu "$output")

if $dry_run; then
  printf '%q ' "${command[@]}"
  printf '\n'
  exit 0
fi
if ! command -v dmgbuild >/dev/null 2>&1; then
  echo "缺少打包工具 dmgbuild；安装方式见 packaging/dmg/README.md（不是应用依赖）" >&2
  exit 1
fi

"${command[@]}"
