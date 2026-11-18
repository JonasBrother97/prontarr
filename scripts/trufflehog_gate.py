#!/usr/bin/env python3
"""Evaluate TruffleHog JSON without logging credential values."""
import json
import hashlib
import sys


def evaluate(report: str, status: int) -> int:
    if status not in (0, 183):
        print(f'TruffleHog failed to run (exit {status}); raw logs withheld.')
        return 1
    findings = 0
    ignored = 0
    for line in report.splitlines():
        if not line.strip():
            continue
        entry = json.loads(line)
        source = entry.get('SourceMetadata', {}).get('Data', {}).get('Git', {})
        # An exact synthetic URI from the connection validation contract.
        # Also recognize historical copies in this gate and its documentation.
        # Do not exempt whole files, detectors or other credentials.
        if (entry.get('DetectorName') == 'URI'
                and source.get('file') in {'src/tests.zig', 'scripts/trufflehog_gate.py', 'docs/security-ci.md'}
                and hashlib.sha256(entry.get('Raw', '').encode()).hexdigest() == '934d2d3da4ee669bca0223cc5137596994f37d420d71d62a25b1fd2f91965840'):
            ignored += 1
            continue
        findings += 1
    print(f'TruffleHog findings: {findings}; exact synthetic fixtures: {ignored}')
    if status == 183 and findings == 0 and ignored == 0:
        print('Scanner reported findings but produced no usable records.')
        return 1
    return int(findings > 0)


if __name__ == '__main__':
    sys.exit(evaluate(sys.stdin.read(), int(sys.argv[1])))
