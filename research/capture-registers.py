#!/usr/bin/env python3
"""Capture raw read-only VCP snapshots; never send Set VCP commands."""
import argparse
import datetime
import functools
import json
import os
from pathlib import Path
import re
import signal
import subprocess


def parse_snapshot(raw):
    rows = []
    sentinel = None
    for line in raw.splitlines():
        match = re.fullmatch(r'seed=6e code=([0-9a-f]+) w=([0-9a-f]+) r=([0-9a-f]+) bytes=(.*)', line)
        if not match:
            continue
        code = int(match[1], 16)
        reply = bytes.fromhex(match[4])
        valid = (int(match[2], 16) == 0 and int(match[3], 16) == 0
                 and len(reply) >= 11 and reply[:3] == b'\x6e\x88\x02'
                 and reply[4] == code
                 and functools.reduce(int.__xor__, reply[:11], 0x50) == 0)
        if code == 0xc8:
            sentinel = reply[6:10] if valid and reply[3] == 0 else None
            continue
        row = {'code': f'{code:02x}', 'raw': reply.hex(' ')}
        if not valid or sentinel is None:
            row['status'] = 'invalid-transport-or-frame'
        elif reply[3]:
            row['status'] = 'unsupported'
        elif reply[6:10] == sentinel:
            row['status'] = 'stale-sentinel-payload'
        else:
            # Diagnostic evidence only: zero maxima can be legitimate for
            # discrete/read-only fields; this does not authorize any writes.
            row.update(status='fresh-reply', maximum=int.from_bytes(reply[6:8], 'big'),
                       current=int.from_bytes(reply[8:10], 'big'))
        rows.append(row)
    modes = [r.get('current') for r in rows if r['code'] == 'dc']
    return {'modeBeforeAfter': modes,
            'modeEndpointsAgree': len(modes) == 2 and modes[0] is not None and modes[0] == modes[1],
            'registers': rows}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('label', help='User-reported OSD mode; raw mode endpoints are recorded separately')
    args = parser.parse_args()
    if not re.fullmatch(r'[a-zA-Z0-9_-]+', args.label):
        parser.error('Use letters, numbers, underscores or hyphens for the label.')
    root = Path(__file__).resolve().parent.parent
    stamp = datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
    folder = root / 'build/protocol-snapshots' / f'{stamp}-{args.label}'
    folder.mkdir(parents=True)
    processes = subprocess.check_output(['ps', '-axo', 'pid=,command='], text=True)
    pids = [int(line.strip().split(None, 1)[0]) for line in processes.splitlines()
            if line.strip().split(None, 1)[-1].endswith('Python scripts/capture-modes.py')]
    paused = []
    try:
        for pid in pids:
            os.kill(pid, signal.SIGSTOP)
            paused.append(pid)
        for index in range(1, 3):
            result = subprocess.run([str(root / '.build.noindex/read-registers')],
                                    capture_output=True, text=True, timeout=35)
            (folder / f'{index}.txt').write_text(result.stdout)
            report = parse_snapshot(result.stdout)
            report.update(label=args.label, capturedAt=datetime.datetime.now().isoformat(),
                          exitCode=result.returncode, stderr=result.stderr)
            (folder / f'{index}.json').write_text(json.dumps(report, indent=2))
            print(json.dumps({'path': str(folder / f'{index}.json'),
                              'modeBeforeAfter': report['modeBeforeAfter'],
                              'modeEndpointsAgree': report['modeEndpointsAgree']}), flush=True)
            if result.returncode:
                raise SystemExit(result.returncode)
    finally:
        for pid in paused:
            try:
                os.kill(pid, signal.SIGCONT)
            except ProcessLookupError:
                pass
