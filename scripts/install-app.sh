#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
source_app="$project_dir/build/CodexNotchMonitor.app"
target_app="/Applications/CodexNotchMonitor.app"
architecture="${1:-native}"

"$project_dir/scripts/build-app.sh" "$architecture"

if [[ -d "$target_app" ]]; then
  backup_dir="$project_dir/build/backups"
  mkdir -p "$backup_dir"
  backup_app="$backup_dir/CodexNotchMonitor-$(date +%Y%m%d-%H%M%S).app"
  ditto "$target_app" "$backup_app"
  echo "已备份旧版本：$backup_app"
fi

pkill -f '/Applications/CodexNotchMonitor.app/Contents/MacOS/CodexNotchMonitor' 2>/dev/null || true
ditto "$source_app" "$target_app"
codesign --verify --deep --strict "$target_app"
if [[ "${CODEX_NOTCH_INSTALL_HOOKS:-0}" == "1" ]]; then
  "$project_dir/scripts/install-hooks.py"
else
  echo "已保留现有 Hook 配置；如需首次安装或重建 Hook，请单独运行 scripts/install-hooks.py"
fi
open "$target_app"

echo "应用已安装：$target_app"
