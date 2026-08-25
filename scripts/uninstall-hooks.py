#!/usr/bin/env python3
import json
import os
import pathlib


def main() -> int:
    codex_home = pathlib.Path(os.environ.get("CODEX_HOME", pathlib.Path.home() / ".codex"))
    config_path = codex_home / "hooks.json"
    if not config_path.exists():
        print("没有 hooks.json，无需卸载。")
        return 0

    document = json.loads(config_path.read_text(encoding="utf-8"))
    hooks = document.get("hooks", {})
    marker = "CodexMonitorHook"
    removed = 0
    for event, groups in list(hooks.items()):
        kept = []
        for group in groups:
            handlers = group.get("hooks", []) if isinstance(group, dict) else []
            if any(marker in str(handler.get("command", "")) for handler in handlers if isinstance(handler, dict)):
                removed += 1
            else:
                kept.append(group)
        if kept:
            hooks[event] = kept
        else:
            hooks.pop(event, None)

    config_path.write_text(json.dumps(document, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    os.chmod(config_path, 0o600)
    print(f"已移除 {removed} 个 CodexNotchMonitor Hook。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
