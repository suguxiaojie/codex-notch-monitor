#!/usr/bin/env python3
import importlib.util
import pathlib


project = pathlib.Path(__file__).resolve().parent.parent
script = project / "scripts/install-hooks.py"
spec = importlib.util.spec_from_file_location("install_hooks", script)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)

third_party = {
    "type": "command",
    "command": "/usr/bin/node /tmp/existing-hook.js",
    "timeout": 300,
}
old_monitor = {
    "type": "command",
    "command": "/Applications/CodexNotchMonitor.app/Contents/Helpers/CodexMonitorHook",
    "timeout": 2,
    "async": True,
}
document = {
    "hooks": {
        "PreToolUse": [
            {"hooks": [third_party]},
            {"hooks": [old_monitor]},
        ]
    }
}

command = "/Applications/CodexNotchMonitor.app/Contents/Helpers/CodexMonitorHook"
result = module.merge_monitor_hooks(document, command)

for event in module.EVENTS:
    groups = result["hooks"][event]
    monitor_handlers = [
        handler
        for group in groups
        for handler in group.get("hooks", [])
        if "CodexNotchMonitor" in handler.get("command", "")
    ]
    assert len(monitor_handlers) == 1, f"{event}: monitor hook should be unique"
    handler = monitor_handlers[0]
    assert handler["timeout"] == 2, f"{event}: timeout"
    assert "async" not in handler, f"{event}: async must be omitted for compatibility"

pre_tool_handlers = [
    handler
    for group in result["hooks"]["PreToolUse"]
    for handler in group.get("hooks", [])
]
assert third_party in pre_tool_handlers, "third-party hook must be preserved"
print("Install hooks tests: 9/9 synchronous monitor events passed")
