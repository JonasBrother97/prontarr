#!/usr/bin/env python3
"""Local-only API, persistence and boundary tests; no homelab access."""
import concurrent.futures
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time
import unittest
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
BASE = 'http://127.0.0.1:5882'


def request(path, body=None, method=None, headers=None):
    data = json.dumps(body).encode() if body is not None else None
    h = {'Content-Type': 'application/json'} | (headers or {})
    req = urllib.request.Request(BASE + path, data=data, method=method, headers=h)
    try:
        response = urllib.request.urlopen(req, timeout=5)
    except urllib.error.HTTPError as e:
        response = e
    with response:
        raw = response.read()
        value = json.loads(raw) if response.headers.get_content_type() == 'application/json' else raw
        return response.status, value, response.headers


class ApiTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        with socket.socket() as probe:
            if probe.connect_ex(('127.0.0.1', 5882)) == 0:
                raise RuntimeError('Port 5882 is already in use. Stop your manual instance before testing.')
        cls.temp = tempfile.TemporaryDirectory(prefix='prontarr-test-')
        cls.log = tempfile.TemporaryFile()
        cls.env = os.environ | {'PRONTARR_DB': str(Path(cls.temp.name) / 'test.sqlite')}
        cls.process = None
        try:
            cls.start()
        except Exception:
            cls.stop()
            cls.log.close()
            cls.temp.cleanup()
            raise

    @classmethod
    def start(cls):
        cls.process = subprocess.Popen([str(ROOT / 'zig-out/bin/prontarr')], cwd=ROOT, env=cls.env, stdout=cls.log, stderr=cls.log)
        for _ in range(100):
            if cls.process.poll() is not None:
                cls.log.seek(0)
                raise RuntimeError(cls.log.read().decode())
            try:
                if request('/api/health')[0] == 200:
                    return
            except OSError:
                pass
            time.sleep(.05)
        raise RuntimeError('Server did not become ready')

    @classmethod
    def stop(cls):
        if cls.process and cls.process.poll() is None:
            cls.process.terminate()
            try:
                cls.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                cls.process.kill()
                cls.process.wait(timeout=5)

    @classmethod
    def tearDownClass(cls):
        cls.stop()
        cls.log.close()
        cls.temp.cleanup()

    def example(self):
        return json.loads((ROOT / 'docs/example-input.json').read_text())

    def test_health_explicitly_disables_live_actions(self):
        status, body, headers = request('/api/health')
        self.assertEqual(status, 200)
        self.assertFalse(body['live_actions_enabled'])
        self.assertEqual(body['mode'], 'simulation')
        self.assertEqual(headers['Cache-Control'], 'no-store')

    def test_embedded_frontend_has_correct_content_types(self):
        for path, content_type in [('/', 'text/html'), ('/app.js', 'text/javascript'), ('/app.css', 'text/css')]:
            status, body, headers = request(path)
            self.assertEqual(status, 200)
            self.assertEqual(headers.get_content_type(), content_type)
            self.assertGreater(len(body), 100)

    def test_compact_selected_before_existing_4k_candidate(self):
        status, decision, _ = request('/api/simulate', self.example())
        self.assertEqual(status, 200)
        self.assertEqual(decision['candidate_id'], 'compact')
        self.assertEqual(decision['action'], 'download_compact')
        self.assertFalse(decision['may_remove_first_copy'])

    def test_blocked_or_dubbed_source_is_never_chosen(self):
        for key in ['original_audio', 'arr_approved']:
            data = self.example()
            data['candidates'][0][key] = False
            status, decision, _ = request('/api/simulate', data)
            self.assertEqual(status, 200)
            self.assertEqual(decision['action'], 'wait')

    def test_season_scope_requires_every_episode(self):
        data = self.example()
        data['snapshot'] = {'stage': 'compact_downloading', 'expected_episodes': 8, 'imported_episodes': 7, 'upgrade_import_confirmed': False}
        self.assertEqual(request('/api/simulate', data)[1]['action'], 'wait')
        data['snapshot']['imported_episodes'] = 8
        self.assertEqual(request('/api/simulate', data)[1]['action'], 'search_upgrade')

    def test_validation_rejects_invalid_counts_and_policy(self):
        data = self.example()
        data['snapshot']['expected_episodes'] = 0
        self.assertEqual(request('/api/simulate', data)[0], 400)
        self.assertEqual(request('/api/simulate', {})[0], 400)
        self.assertEqual(request('/api/policy', {'max_compact_bytes': 0}, 'PUT')[0], 400)
        self.assertEqual(request('/api/policy', {'max_resolution': 2160}, 'PUT')[0], 400)

    def test_browser_boundaries(self):
        self.assertEqual(request('/api/health', headers={'Host': 'attacker.example'})[0], 403)
        self.assertEqual(request('/api/plans', self.example(), headers={'Origin': 'https://attacker.example'})[0], 403)
        self.assertEqual(request('/api/plans', self.example(), headers={'Content-Type': 'text/plain'})[0], 415)
        self.assertEqual(request('/api/unknown')[0], 404)
        self.assertEqual(request('/api/simulate', self.example(), headers={'Origin': 'http://127.0.0.1:5173'})[0], 200)

    def test_concurrent_writes_produce_distinct_plans(self):
        def save(index):
            data = self.example()
            data['title'] = f'Concurrent simulation {index}'
            status, body, _ = request('/api/plans', data)
            self.assertEqual(status, 201)
            return body['id']
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            ids = list(pool.map(save, range(12)))
        self.assertEqual(len(set(ids)), 12)

    def test_restart_preserves_policy_and_plan(self):
        policy = {'max_compact_bytes': 2 * 1024**3, 'min_seeders': 7, 'min_resolution': 720, 'max_resolution': 1080}
        self.assertEqual(request('/api/policy', policy, 'PUT')[0], 200)
        data = self.example()
        data['title'] = 'Persistence proof'
        status, saved, _ = request('/api/plans', data)
        self.assertEqual(status, 201)
        self.stop()
        self.start()
        self.assertEqual(request('/api/policy')[1], policy)
        plans = request('/api/plans')[1]['items']
        self.assertTrue(any(p['id'] == saved['id'] and p['title'] == data['title'] for p in plans))


if __name__ == '__main__':
    unittest.main(verbosity=2)
