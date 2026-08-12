#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
app_dir="$project_dir/build/CodexNotchMonitor.app"

cd "$project_dir"
swift build -c release

mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources" "$app_dir/Contents/Helpers"
cp "$project_dir/.build/release/CodexNotchMonitor" "$app_dir/Contents/MacOS/CodexNotchMonitor"
cp "$project_dir/.build/release/CodexMonitorHook" "$app_dir/Contents/Helpers/CodexMonitorHook"
cp "$project_dir/Resources/Info.plist" "$app_dir/Contents/Info.plist"
chmod 755 "$app_dir/Contents/MacOS/CodexNotchMonitor" "$app_dir/Contents/Helpers/CodexMonitorHook"
codesign --force --deep --sign - "$app_dir"

echo "$app_dir"
