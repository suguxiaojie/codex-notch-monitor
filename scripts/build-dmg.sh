#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$project_dir/Resources/Info.plist")"
architecture="${1:-universal}"
case "$architecture" in
  native)
    artifact_architecture="$(uname -m)"
    ;;
  arm64|x86_64|universal)
    artifact_architecture="$architecture"
    ;;
  *)
    echo "用法：$0 [native|arm64|x86_64|universal]" >&2
    exit 2
    ;;
esac
app_path="$project_dir/build/CodexNotchMonitor.app"
dmg_path="$project_dir/build/CodexNotchMonitor-v${version}-${artifact_architecture}.dmg"
staging_dir="$(mktemp -d /tmp/codex-notch-dmg.XXXXXX)"

cleanup() {
  rm -rf "$staging_dir"
}
trap cleanup EXIT

"$project_dir/scripts/build-app.sh" "$architecture"
codesign --verify --deep --strict "$app_path"

ditto "$app_path" "$staging_dir/CodexNotchMonitor.app"
ln -s /Applications "$staging_dir/Applications"

rm -f "$dmg_path"
hdiutil create \
  -volname "Codex Notch Monitor" \
  -srcfolder "$staging_dir" \
  -format UDZO \
  -imagekey zlib-level=9 \
  -ov \
  "$dmg_path" >/dev/null

hdiutil verify "$dmg_path" >/dev/null
shasum -a 256 "$dmg_path"
echo "$dmg_path"
