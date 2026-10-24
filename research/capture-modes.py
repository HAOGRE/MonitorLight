#!/usr/bin/env python3
"""Read-only mode capture at four scheduled samples per second."""
import argparse
import json
from pathlib import Path
import subprocess
import time

parser = argparse.ArgumentParser()
parser.add_argument('--helper', default='.build.noindex/monitor-ddc-test')
parser.add_argument('--uuid', default='57CF2C6E-B43C-8507-0857-D6964E3302DB')
parser.add_argument('--duration', type=float, default=1800)
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
changes = root / 'build/mode-capture.jsonl'
samples = root / 'build/mode-capture-debug.jsonl'
health = root / 'build/mode-capture-health.json'
rows = changes.read_text().splitlines() if changes.exists() else []
last = json.loads(rows[-1])['value'] if rows else None
period = 0.25
started = next_tick = time.monotonic()
recent = []
tick = 0
while time.monotonic() - started < args.duration:
    time.sleep(max(0, next_tick - time.monotonic()))
    sample_start = time.monotonic()
    wall_start = time.time()
    try:
        result = subprocess.run([str(root / args.helper), 'get', args.uuid, 'picture-mode'],
                                capture_output=True, text=True, timeout=4)
        payload = json.loads(result.stdout)
        value = payload.get('current') if result.returncode == 0 else None
    except (subprocess.TimeoutExpired, ValueError) as error:
        payload = {'error': str(type(error).__name__)}
        value = None
    with samples.open('a') as stream:
        stream.write(json.dumps({'time': wall_start, 'duration': time.monotonic() - sample_start,
                                 'value': value, 'payload': payload}) + '\n')
    if value is not None and value != last:
        row = {'time': wall_start, 'value': value}
        with changes.open('a') as stream:
            stream.write(json.dumps(row) + '\n')
        print(json.dumps(row), flush=True)
        last = value
    recent.append(sample_start)
    recent = recent[-40:]
    health.write_text(json.dumps({'updated': time.time(), 'targetHz': 4, 'samples': tick + 1,
        'observedHz': (len(recent)-1)/(recent[-1]-recent[0]) if len(recent)>1 else None,
        'lastValue': value, 'lastError': payload.get('error')}, indent=2))
    if tick % 40 == 0:
        print('Capture active: target 4 samples/second; mode', value, flush=True)
    tick += 1
    next_tick += period
    if time.monotonic() > next_tick + period:
        next_tick = time.monotonic()  # Never overlap I2C requests or pile up missed samples.
