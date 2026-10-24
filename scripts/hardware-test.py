#!/usr/bin/env python3
"""Small, reversible physical-display test. Explicitly invoked; never runs at launch."""
import json
import subprocess
from pathlib import Path

root = Path(__file__).resolve().parent.parent
helper = root / ".build.noindex/MonitorLight.app/Contents/Helpers/monitor-ddc"

def call(*args):
    result = subprocess.run([str(helper), *map(str, args)], capture_output=True, text=True, timeout=12)
    payload = json.loads(result.stdout)
    if result.returncode:
        raise RuntimeError(payload)
    return payload

screens = call("list")
assert screens and screens[0]["ddc"] is True, screens
screen = screens[0]
uuid = screen["uuid"]
originals = call("probe", uuid)
report = {"display": screen, "before": originals, "tests": []}
changed = []
try:
    for feature in ("brightness", "volume"):
        initial = originals[feature]
        if "current" not in initial:
            report["tests"].append({"feature": feature, "unavailable": initial.get("error", "unknown")})
            continue
        target = initial["current"] - 1 if initial["current"] else 1
        # Record before writing, so restoration still runs if read-back fails.
        changed.append(feature)
        result = call("set", uuid, feature, target)
        assert result["verified"] and result["current"] == target, result
        again = call("get", uuid, feature)
        assert again["current"] == target, again
        restored = call("set", uuid, feature, initial["current"])
        assert restored["current"] == initial["current"]
        changed.remove(feature)
        report["tests"].append({"feature": feature, "written": target, "read_back": again, "restored": restored})
finally:
    for feature in reversed(changed):
        call("set", uuid, feature, originals[feature]["current"])
    report["after"] = call("probe", uuid)
    (root / "build/hardware-test.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
assert report["after"] == originals, report
assert any(item.get("feature") == "volume" and "restored" in item for item in report["tests"]), report
print(json.dumps(report, ensure_ascii=False, indent=2))
