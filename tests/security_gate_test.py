"""Secret scan gates fail closed and never display raw finding values."""
import contextlib
import importlib.util
import io
import json
import runpy
import sys
from unittest.mock import patch
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('gate', Path(__file__).resolve().parents[1] / 'scripts/trufflehog_gate.py')
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)


class SecretGateTests(unittest.TestCase):
    def entry(self, raw, path='src/tests.zig', detector='URI'):
        return json.dumps({'DetectorName': detector, 'Raw': raw,
                           'SourceMetadata': {'Data': {'Git': {'file': path}}}})

    def run_gate(self, report, status):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            result = gate.evaluate(report, status)
        return result, output.getvalue()

    def test_known_fixture_only_in_expected_context(self):
        fixture = 'http://' + 'user:secret' + '@example.test'
        self.assertEqual(self.run_gate(self.entry(fixture), 183)[0], 0)
        for path, detector in [('src/real.zig', 'URI'), ('src/tests.zig', 'GitHub')]:
            self.assertEqual(self.run_gate(self.entry(fixture, path, detector), 183)[0], 1)

    def test_findings_fail_without_printing_raw_values(self):
        raw = 'unexpected-sensitive-value'
        result, output = self.run_gate(self.entry(raw), 183)
        self.assertEqual(result, 1)
        self.assertNotIn(raw, output)

    def test_cli_consumes_stdin_and_propagates_the_scan_exit_status(self):
        script=Path(__file__).resolve().parents[1] / 'scripts/trufflehog_gate.py'
        for status, expected in [(0, 0), (125, 1), (183, 1)]:
            with patch.object(sys, 'stdin', io.StringIO('')), patch.object(sys, 'argv', [str(script), str(status)]), contextlib.redirect_stdout(io.StringIO()):
                with self.assertRaises(SystemExit) as result:
                    runpy.run_path(str(script), run_name='__main__')
                self.assertEqual(result.exception.code, expected)

    def test_scanner_failure_or_missing_records_cannot_pass(self):
        for status, expected in [(0, 0), (125, 1), (183, 1)]:
            self.assertEqual(self.run_gate('', status)[0], expected)
        with self.assertRaises(json.JSONDecodeError):
            self.run_gate('{broken', 0)


if __name__ == '__main__':
    unittest.main()
