#!/usr/bin/env python3
"""Evaluate TruffleHog JSON without logging credential values."""
import json
from pathlib import Path
import sys


def evaluate(report: Path, status: int) -> int:
    if status not in (0, 183):
        print(f'TruffleHog failed to run (exit {status}); raw logs withheld.')
        return 1
    findings = 0
    ignored = 0
    for line in report.read_text().splitlines():
        if not line.strip():
            continue
        entry = json.loads(line)
        source = entry.get('SourceMetadata', {}).get('Data', {}).get('Git', {})
        # An exact synthetic URI from the connection validation contract.
        # Do not exempt the file, detector or other example.test credentials.
        if (entry.get('DetectorName') == 'URI'
                and source.get('file') == 'src/tests.zig'
                and entry.get('Raw') == ('http://' + 'user:secret' + '@example.test')):
            ignored += 1
            continue
        findings += 1
    print(f'TruffleHog findings: {findings}; exact synthetic fixtures: {ignored}')
    if status == 183 and findings == 0 and ignored == 0:
        print('Scanner reported findings but produced no usable records.')
        return 1
    return int(findings > 0)


if __name__ == '__main__':
    sys.exit(evaluate(Path(sys.argv[1]), int(sys.argv[2])))
