#!/usr/bin/env python3
import json
import os
import pathlib
import shutil
import sys
from datetime import datetime


EVENTS = [
    "SessionStart",
    "SessionEnd",
    "UserPromptSubmit",
    "PreToolUse",
    "PostToolUse",
    "PermissionRequest",
    "SubagentStart",
    "SubagentStop",
    "Stop",
]


def merge_monitor_hooks(document: dict, command: str) -> dict:
    hooks = document.setdefault("hooks", {})
    marker = "CodexNotchMonitor"
    for event in EVENTS:
        groups = hooks.setdefault(event, [])
        filtered = []
        for group in groups:
            handlers = group.get("hooks", []) if isinstance(group, dict) else []
            if any(marker in str(handler.get("command", "")) for handler in handlers if isinstance(handler, dict)):
                continue
            filtered.append(group)

        # Some released Codex builds still skip background hooks even though
        # newer documentation describes async support. The relay only writes a
        # tiny local JSON event, so a synchronous two-second ceiling is both
        # compatible and short enough not to hold up normal tool execution.
        handler = {
            "type": "command",
            "command": command,
            "timeout": 2,
        }
        filtered.append({"hooks": [handler]})
        hooks[event] = filtered
    return document


def main() -> int:
    project = pathlib.Path(__file__).resolve().parent.parent
    installed_helper = pathlib.Path("/Applications/CodexNotchMonitor.app/Contents/Helpers/CodexMonitorHook")
    built_helper = project / "build/CodexNotchMonitor.app/Contents/Helpers/CodexMonitorHook"
    helper = installed_helper if installed_helper.is_file() else built_helper
    if not helper.is_file():
        print("请先运行 scripts/build-app.sh 或 scripts/install-app.sh", file=sys.stderr)
        return 1

    codex_home = pathlib.Path(os.environ.get("CODEX_HOME", pathlib.Path.home() / ".codex"))
    config_path = codex_home / "hooks.json"
    codex_home.mkdir(parents=True, exist_ok=True)

    if config_path.exists():
        try:
            document = json.loads(config_path.read_text(encoding="utf-8"))
        except Exception as error:
            print(f"现有 hooks.json 无法解析，未做修改：{error}", file=sys.stderr)
            return 2
        timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
        backup = config_path.with_name(f"hooks.json.backup-{timestamp}")
        shutil.copy2(config_path, backup)
        print(f"已备份：{backup}")
    else:
        document = {"description": "User-level Codex lifecycle hooks", "hooks": {}}

    command = str(helper)
    merge_monitor_hooks(document, command)

    temporary = config_path.with_suffix(".json.tmp")
    temporary.write_text(json.dumps(document, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    os.chmod(temporary, 0o600)
    temporary.replace(config_path)
    print(f"已安装 Hook：{config_path}")
    print("请在 Codex 中打开 /hooks，审核并信任新增的用户级 Hook。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
