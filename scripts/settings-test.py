#!/usr/bin/env python3
"""Reversible, readback-verified EW3270U controls test. Requires the display.

Preserve the currently selected mode and settings. Do not run while manually
changing picture modes in the physical OSD.
"""
import json
from pathlib import Path
import subprocess
import time
root=Path(__file__).resolve().parent.parent
helper=root/'.build.noindex/MonitorLight.app/Contents/Helpers/monitor-ddc'
displays=json.loads(subprocess.check_output([str(helper),'list']))
display=next(d for d in displays if d['name']=='BenQ EW3270U')
def call(*args):
    result=subprocess.run([str(helper),args[0],display['uuid'],*args[1:]],capture_output=True,text=True,timeout=8)
    response=json.loads(result.stdout)
    if result.returncode:
        if args[0] == 'set' and response.get('writeSent'):
            for _ in range(4):
                time.sleep(.25)
                try:
                    fresh=subprocess.run([str(helper),'get',display['uuid'],args[1]],capture_output=True,text=True,timeout=2)
                    data=json.loads(fresh.stdout)
                    if fresh.returncode==0 and data.get('current')==int(args[2]):
                        return {**data,'verified':True,'freshProcess':True}
                except (subprocess.TimeoutExpired,ValueError):
                    continue
        raise RuntimeError(response.get('error',response))
    return response
report={'before':call('settings'),'primaryBefore':call('probe'),'tests':[]}
# The picture mode must have a known restorable encoding before any test.
original_mode=report['before']['picture-mode']['current']
if original_mode not in [0,5,11,12,14,15,18,275,531,787,1043]:
    raise SystemExit('The current picture mode cannot be restored safely; select a known mode first.')
try:
    for mode in [0,5,11,12,14,15,18,275,531,787,1043]:
        confirmed=call('set','picture-mode',str(mode))
        readback=call('get','picture-mode')
        assert confirmed['current']==readback['current']==mode
        report['tests'].append({'feature':'picture-mode','target':mode,'verified':True})
finally:
    call('set','picture-mode',str(original_mode))
    for feature in ['brightness','volume']:
        if 'current' in report['primaryBefore'][feature]:
            call('set',feature,str(report['primaryBefore'][feature]['current']))
    (root/'build/settings-verification.json').write_text(json.dumps(report,ensure_ascii=False,indent=2))
for feature, target in [('sharpness',4),('response-time',0),('aspect-ratio',5)]:
    original=call('get',feature)['current']
    try:
        confirmed=call('set',feature,str(target))
        readback=call('get',feature)
        assert confirmed['current']==readback['current']==target
        report['tests'].append({'feature':feature,'target':target,'verified':True})
    finally:
        call('set',feature,str(original))
        (root/'build/settings-verification.json').write_text(json.dumps(report,ensure_ascii=False,indent=2))
report['after']=call('settings')
(root/'build/settings-verification.json').write_text(json.dumps(report,ensure_ascii=False,indent=2))
print('Picture modes, sharpness, AMA and aspect ratio verified and restored.')
