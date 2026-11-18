#!/usr/bin/env python3
"""Contract tests against isolated fake Arr/qBittorrent HTTP services."""
import http.server
import concurrent.futures
import json
import os
from pathlib import Path
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from urllib.parse import urlsplit
from api_smoke import request, ROOT

HASH_A, HASH_B, HASH_C = 'a' * 40, 'b' * 40, 'c' * 40


class FixtureServer(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def handle_error(self, request, client_address):
        if isinstance(sys.exception(), (BrokenPipeError, ConnectionResetError, ssl.SSLError)):
            return  # Expected when the test client rejects a certificate or times out.
        super().handle_error(request, client_address)


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def reply(self, data, status=200, content_type='application/json'):
        body = json.dumps(data).encode() if content_type == 'application/json' else data
        self.send_response(status)
        self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_POST(self):
        self.server.calls.append(('POST', urlsplit(self.path).path))
        self.reply({'error': 'Mutations are forbidden'}, 405)

    def do_GET(self):
        path = urlsplit(self.path).path
        self.server.calls.append(('GET', path))
        mode = self.server.mode
        if path.startswith(('/radarr/', '/sonarr/')) and self.headers.get('X-Api-Key') != 'fixture-secret':
            return self.reply({}, 401)
        if path == '/radarr/api/v3/system/status':
            if mode == 'auth':
                return self.reply({'secret': 'fixture-secret'}, 403)
            if mode == 'redirect':
                self.send_response(302)
                self.send_header('Location', '/credential-trap')
                self.end_headers()
                return
            if mode == 'huge':
                return self.reply(b'x' * (2 * 1024 * 1024 + 1), content_type='text/plain')
            if mode == 'timeout':
                self.server.timeout_started.set()
                time.sleep(3.5)
        if path.endswith('/system/status'):
            return self.reply({'version': 'fixture-1.0', 'apiKey': 'upstream-secret-not-for-browser'})
        if path == '/qb/api/v2/app/version':
            return self.reply(b'v5.1.0', content_type='text/plain')
        if path == '/qb/api/v2/torrents/info':
            def torrent(hash_id, state='downloading', progress=.01):
                return {'hash': hash_id, 'name': 'Fixture torrent', 'state': state, 'progress': progress,
                        'size': 20 * 1024**3, 'dlspeed': 1024**2, 'num_seeds': 10, 'eta': 8640000}
            return self.reply([torrent(HASH_A), torrent(HASH_B, 'stoppedDL'), torrent(HASH_C), torrent('invalid', progress=2)])
        if path == '/radarr/api/v3/queue':
            return self.reply({'totalRecords': 30, 'records': [
                {'id': 1, 'movieId': 1, 'title': 'Available movie', 'downloadId': HASH_A.upper(), 'quality': {'quality': {'resolution': 2160}}, 'customFormatScore': 1100},
                {'id': 2, 'movieId': 2, 'title': 'Paused movie', 'downloadId': HASH_B, 'quality': {'quality': {'resolution': 2160}}},
                {'id': 3, 'movieId': 3, 'title': 'Unknown metadata', 'downloadId': HASH_C},
                {'id': 4, 'movieId': 4, 'title': 'New large movie', 'downloadId': HASH_C, 'quality': {'quality': {'resolution': 2160}}},
            ]})
        if path == '/sonarr/api/v3/queue':
            return self.reply({'totalRecords': 3, 'records': [
                {'id': 10, 'seriesId': 5, 'episodeId': 10, 'title': 'Season episode A', 'downloadId': HASH_C, 'quality': {'quality': {'resolution': 2160}}},
                {'id': 11, 'seriesId': 5, 'episodeId': 11, 'title': 'Season episode B', 'downloadId': HASH_C, 'quality': {'quality': {'resolution': 2160}}},
                {'id': 12, 'seriesId': 6, 'title': 'Unknown episode scope', 'downloadId': HASH_C},
            ]})
        if path == '/radarr/api/v3/movie/1':
            return self.reply({'hasFile': True, 'movieFile': {'id': 100}})
        if path in ['/radarr/api/v3/movie/2', '/radarr/api/v3/movie/4']:
            return self.reply({'hasFile': False})
        if path == '/radarr/api/v3/movie/3':
            return self.reply({})
        if path.startswith('/sonarr/api/v3/episode/'):
            return self.reply({'hasFile': False, 'episodeFileId': 0, 'seasonNumber': 1, 'episodeNumber': int(path.rsplit('/', 1)[1])})
        return self.reply({}, 404)


class ObserveContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        with socket.socket() as probe:
            if probe.connect_ex(('127.0.0.1', 5882)) == 0:
                raise RuntimeError('Stop your manual Prontarr instance before contract testing.')
        cls.temp = tempfile.TemporaryDirectory(prefix='prontarr-contract-')
        cls.folder = Path(cls.temp.name)
        cls.fixture = FixtureServer(('127.0.0.1', 0), Handler)
        cls.fixture.calls, cls.fixture.mode = [], 'normal'
        cls.fixture.timeout_started = threading.Event()
        threading.Thread(target=cls.fixture.serve_forever, daemon=True).start()
        base = f'http://127.0.0.1:{cls.fixture.server_port}'
        cls.config = {name: {'url': base + '/' + prefix, **({'api_key': 'fixture-secret'} if name != 'qbittorrent' else {})}
                      for name, prefix in [('radarr', 'radarr'), ('sonarr', 'sonarr'), ('qbittorrent', 'qb')]}
        cls.config_file = cls.folder/'connections.json'
        cls.write_config()
        cls.log = tempfile.TemporaryFile()
        cls.process = None
        cls.start()

    @classmethod
    def write_config(cls):
        cls.config_file.write_text(json.dumps(cls.config))
        cls.config_file.chmod(0o600)

    @classmethod
    def start(cls):
        env = os.environ | {'PRONTARR_DB': str(cls.folder/'test.sqlite'), 'PRONTARR_CONNECTIONS': str(cls.config_file)}
        cls.process = subprocess.Popen([str(ROOT/'zig-out/bin/prontarr')], env=env, cwd=ROOT, stdout=cls.log, stderr=cls.log)
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
        raise RuntimeError('Server startup failed')

    @classmethod
    def stop(cls):
        if cls.process and cls.process.poll() is None:
            cls.process.terminate()
            cls.process.wait(timeout=5)

    @classmethod
    def tearDownClass(cls):
        cls.stop()
        cls.fixture.shutdown()
        cls.fixture.server_close()
        cls.log.close()
        cls.temp.cleanup()

    def setUp(self):
        self.fixture.mode = 'normal'
        self.fixture.calls.clear()
        self.fixture.timeout_started.clear()

    def observe(self):
        # urllib timeout is 5s; only the isolated timeout case approaches 3s.
        status, data, _ = request('/api/observe', {})
        self.assertEqual(status, 200)
        self.assertFalse(data['live_actions_enabled'])
        self.assertNotIn('fixture-secret', json.dumps(data))
        self.assertNotIn('upstream-secret', json.dumps(data))
        self.assertTrue(all(method == 'GET' for method, _ in self.fixture.calls))
        return data

    def test_normalization_identity_and_read_only_contract(self):
        data = self.observe()
        self.assertTrue(all(s['connected'] for s in data['services']))
        self.assertTrue(data['services'][0]['truncated'])
        self.assertEqual(len(data['torrents']), 3)  # Invalid progress discarded.
        rows = {r['title']: r for r in data['items']}
        self.assertEqual(rows['Available movie']['advice'], 'keep_upgrade')
        self.assertEqual(rows['Available movie']['file_id'], 100)
        self.assertIsNotNone(rows['Available movie']['torrent'])  # Case-insensitive hash join.
        self.assertEqual(rows['Paused movie']['advice'], 'respect_pause')
        self.assertEqual(rows['New large movie']['advice'], 'consider_compact')
        self.assertEqual(rows['Unknown metadata']['advice'], 'needs_review')
        self.assertIsNone(rows['Unknown metadata']['has_file'])
        self.assertEqual(rows['Unknown episode scope']['advice'], 'needs_review')
        self.assertEqual(rows['Season episode A']['advice'], 'needs_review')
        self.assertTrue(rows['Season episode B']['multi_episode_download'])
        self.assertEqual(rows['Season episode B']['season_number'], 1)
        self.assertEqual(rows['Season episode B']['episode_number'], 11)
        self.assertEqual(rows['Available movie']['custom_format_score'], 1100)
        self.assertIsNone(data['torrents'][0]['eta_seconds'])

    def test_configuration_endpoint_never_returns_credentials(self):
        status, data, _ = request('/api/connections')
        self.assertEqual(status, 200)
        self.assertTrue(all(s['configured'] for s in data['items']))
        self.assertNotIn('secret', json.dumps(data))
        self.assertNotIn('url', json.dumps(data))
        self.assertEqual(self.fixture.calls, [])  # Metadata endpoint performs no upstream request.

    def test_auth_failure_is_isolated_and_redacted(self):
        self.fixture.mode = 'auth'
        data = self.observe()
        self.assertEqual(data['services'][0]['error_code'], 'UpstreamUnauthorized')
        self.assertFalse(data['services'][0]['connected'])
        self.assertTrue(data['services'][1]['connected'])

    def test_redirect_is_not_followed_with_credentials(self):
        self.fixture.mode = 'redirect'
        data = self.observe()
        self.assertEqual(data['services'][0]['error_code'], 'UpstreamRedirectBlocked')
        self.assertFalse(any(path == '/credential-trap' for _, path in self.fixture.calls))

    def test_response_size_is_bounded(self):
        self.fixture.mode = 'huge'
        data = self.observe()
        self.assertEqual(data['services'][0]['error_code'], 'ResponseTooLarge')

    def test_stalled_service_has_request_timeout(self):
        self.fixture.mode = 'timeout'
        started = time.monotonic()
        data = self.observe()
        self.assertEqual(data['services'][0]['error_code'], 'UpstreamTimeout')
        self.assertLess(time.monotonic() - started, 4.5)

    def test_observation_requests_are_single_flight(self):
        self.fixture.mode = 'timeout'
        with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
            first = pool.submit(request, '/api/observe', {})
            self.assertTrue(self.fixture.timeout_started.wait(timeout=2))
            status, _, _ = request('/api/observe', {})
            self.assertEqual(status, 409)
            self.assertEqual(first.result(timeout=5)[0], 200)

    def test_self_signed_tls_is_rejected(self):
        cert, key = self.folder/'cert.pem', self.folder/'key.pem'
        subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1', '-subj', '/CN=localhost',
                        '-addext', 'subjectAltName=DNS:localhost,IP:127.0.0.1', '-keyout', str(key), '-out', str(cert)],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        tls = FixtureServer(('127.0.0.1', 0), Handler)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(cert, key)
        tls.socket = context.wrap_socket(tls.socket, server_side=True)
        tls.calls, tls.mode = [], 'normal'
        threading.Thread(target=tls.serve_forever, daemon=True).start()
        original = self.config['radarr']['url']
        try:
            self.stop()
            self.config['radarr']['url'] = f'https://127.0.0.1:{tls.server_port}/radarr'
            self.write_config()
            self.start()
            data = self.observe()
            self.assertEqual(data['services'][0]['error_code'], 'InvalidUpstreamCertificate')
        finally:
            self.stop()
            self.config['radarr']['url'] = original
            self.write_config()
            self.start()
            tls.shutdown()
            tls.server_close()

    def test_world_readable_credentials_refuse_startup(self):
        self.stop()
        self.config_file.chmod(0o644)
        env = os.environ | {'PRONTARR_DB': str(self.folder/'test.sqlite'), 'PRONTARR_CONNECTIONS': str(self.config_file)}
        try:
            result = subprocess.run([str(ROOT/'zig-out/bin/prontarr')], env=env, cwd=ROOT, capture_output=True, timeout=5)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(b'ConnectionsFileMustBePrivate', result.stderr)
            self.assertNotIn(b'fixture-secret', result.stderr)
        finally:
            self.config_file.chmod(0o600)
            self.start()


if __name__ == '__main__':
    unittest.main(verbosity=2)
