#!/usr/bin/env python3
"""Compare stable fresh replies from two repeated snapshot directories."""
import argparse
import json
from pathlib import Path


def stable_snapshot(folder):
    reports = [json.loads((folder / f'{index}.json').read_text()) for index in (1, 2)]
    if not all(r['exitCode'] == 0 and r['modeEndpointsAgree'] for r in reports):
        raise ValueError(f'{folder}: incomplete snapshot or mode endpoints disagree')
    if reports[0]['modeBeforeAfter'] != reports[1]['modeBeforeAfter']:
        raise ValueError(f'{folder}: mode changed between snapshot passes')
    passes = [{r['code']: (r['current'], r['maximum'])
               for r in report['registers'] if r['status'] == 'fresh-reply'}
              for report in reports]
    stable = {code: value for code, value in passes[0].items()
              if passes[1].get(code) == value}
    unstable = sorted((passes[0].keys() | passes[1].keys()) - stable.keys())
    return {'mode': reports[0]['modeBeforeAfter'][0], 'stable': stable,
            'unstable': unstable}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('first', type=Path)
    parser.add_argument('second', type=Path)
    args = parser.parse_args()
    first, second = stable_snapshot(args.first), stable_snapshot(args.second)
    common = first['stable'].keys() & second['stable'].keys()
    print(json.dumps({'first': first, 'second': second,
                      'stableValueDifferences': {
                          code: [first['stable'][code], second['stable'][code]]
                          for code in sorted(common)
                          if first['stable'][code] != second['stable'][code]},
                      'freshInFirstOnly': sorted(first['stable'].keys() - second['stable'].keys()),
                      'freshInSecondOnly': sorted(second['stable'].keys() - first['stable'].keys()),
                      'note': 'Differences are candidates only; they do not establish writable controls.'},
                     indent=2))
