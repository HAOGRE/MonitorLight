#!/usr/bin/env python3
"""Exercise the installed app's public automation API and real display state.

This does not synthesize keys or claim a physical keyboard/UI test. It tests
the same brightness adjustment, volume and mute actions used by those controls.
"""
import json
import math
import subprocess
import time
from pathlib import Path

root = Path(__file__).resolve().parent.parent
app = Path.home() / "Applications/MonitorLight.app"
status_file = Path.home() / "Library/Caches/MonitorLight/status.json"
report = {"tests": [], "physical_keyboard_test": "not exercised by this script; see VERIFICATION.md for user-confirmed physical key test"}
baseline_keyboard_count = None

def wait_for(predicate, description):
    deadline = time.monotonic() + 10
    last = None
    while time.monotonic() < deadline:
        try:
            last = json.loads(status_file.read_text())
            if baseline_keyboard_count is not None and last.get("keyboardActionCount") != baseline_keyboard_count:
                report["interruptedByKeyboard"] = True
                raise AssertionError("Physical keyboard input detected; stop testing and preserve the user's latest settings.")
            if predicate(last):
                return last
        except (OSError, ValueError):
            pass
        time.sleep(.1)
    raise AssertionError(f"{description}: {last}")

def command(path):
    subprocess.run(["open", "-a", str(app), "monitorlight://" + path], check=True, timeout=5)

def value(state, feature):
    item = state["controls"][feature]
    return item["current"] * 100 / item["maximum"]

def at(feature, expected):
    return wait_for(lambda s: not s["controls"].get(feature, {}).get("writing", True)
                    and "current" in s["controls"].get(feature, {})
                    and math.isclose(value(s, feature), expected, abs_tol=.01), f"{feature} -> {expected}")

before = wait_for(lambda s: "current" in s["controls"].get("brightness", {})
                  and "current" in s["controls"].get("volume", {}), "app ready")
assert before["hotkeys"] == "registered", before
original_brightness = value(before, "brightness")
original_volume = value(before, "volume")
report["before"] = before
baseline_keyboard_count = before.get("keyboardActionCount")
try:
    target = max(0, original_brightness - 5) if original_brightness >= 5 else original_brightness + 5
    command(f"adjust-brightness/{target - original_brightness}")
    dimmed = at("brightness", target)
    if dimmed["brightnessMode"] == "software":
        shades = dimmed["shades"]
        assert len(shades) == 1 and shades[0]["visible"], shades
        assert math.isclose(shades[0]["opacity"], (1 - target / 100) * .85, abs_tol=.0001), shades
    report["tests"].append({"action": "brightness adjustment", "target": target, "state": dimmed})
    command(f"brightness/{original_brightness}")
    restored = at("brightness", original_brightness)
    if original_brightness == 100:
        assert all(not shade["visible"] for shade in restored["shades"])

    target_volume = original_volume - 1 if original_volume > 0 else 1
    command(f"volume/{target_volume}")
    at("volume", target_volume)
    command(f"volume/{original_volume}")
    at("volume", original_volume)
    report["tests"].append({"action": "hardware volume", "target": target_volume, "restored": original_volume})

    if original_volume > 0:
        command("mute")
        at("volume", 0)
        command("mute")
        at("volume", original_volume)
        report["tests"].append({"action": "mute and restore", "restored": original_volume})
finally:
    latest = json.loads(status_file.read_text())
    if latest.get("keyboardActionCount") != baseline_keyboard_count:
        report["interruptedByKeyboard"] = True
        report["after"] = latest
    else:
        command(f"brightness/{original_brightness}")
        command(f"volume/{original_volume}")
        at("brightness", original_brightness)
        report["after"] = at("volume", original_volume)
    (root / "build/runtime-smoke-test.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")

print("Installed app smoke test passed: brightness adjustment and restoration, real volume, mute/restore, global hotkey registration.")
print("This script does not synthesize keys; physical keyboard confirmation is documented separately.")
