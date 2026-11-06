import base64
import hashlib
import urllib.error
import urllib.parse
import importlib.util
import json
from compression import zstd
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from unittest.mock import patch

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('uploader', sys.argv.pop(1))
uploader = importlib.util.module_from_spec(spec)
spec.loader.exec_module(uploader)
ROOT = '/nix/store/' + '0' * 32 + '-system'
DEP = '/nix/store/' + '1' * 32 + '-dependency'
COMMUNITY = '/nix/store/' + '2' * 32 + '-community'
NUMTIDE = '/nix/store/' + '3' * 32 + '-numtide'
RUBY = '/nix/store/' + '4' * 32 + '-ruby'
OWN = '/nix/store/' + '5' * 32 + '-existing'
PATHS = [ROOT, DEP, COMMUNITY, NUMTIDE, RUBY, OWN]


class UploadTest(unittest.TestCase):
    def setUp(self):
        self.posts = []
        self.puts = []
        self.failure = None
        self.upload_failure = False
        owner = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def do_GET(self):
                source, name = self.path.strip('/').split('/')
                path = next(p for p in PATHS if p[11:43] + '.narinfo' == name)
                index = PATHS.index(path)
                if owner.failure and source == 'ruby' and path == ROOT:
                    self.send_response(owner.failure)
                    self.end_headers()
                    return
                hit = (source, index) in [('official', 1), ('community', 2), ('numtide', 3), ('ruby', 4), ('own', 5)]
                self.send_response(200 if hit else 404)
                self.end_headers()
                if hit:
                    self.wfile.write(f'StorePath: {path}\n'.encode())

            def do_POST(self):
                body = self.rfile.read(int(self.headers['Content-Length']))
                owner.posts.append((self.path, body, self.headers['Authorization']))
                route = urllib.parse.urlsplit(self.path)
                if route.path.endswith('/multipart-nar'):
                    response = {'narId': 'test-nar', 'uploadId': 'upload/id+test='}
                elif route.path.endswith('/test-nar'):
                    number = urllib.parse.parse_qs(route.query)['partNumber'][0]
                    response = {'uploadUrl': owner.url + '/storage/part-' + number}
                elif route.path.endswith('/complete') or route.path.endswith('/abort'):
                    response = None
                else:
                    self.send_response(404)
                    self.end_headers()
                    return
                self.send_response(415 if self.headers['Content-Type'] != 'application/json' else 200 if response else 204)
                self.end_headers()
                if response:
                    self.wfile.write(json.dumps(response).encode())

            def do_PUT(self):
                body = self.rfile.read(int(self.headers['Content-Length']))
                owner.puts.append((self.path, body, dict(self.headers)))
                self.send_response(503 if owner.upload_failure else 200)
                self.send_header('ETag', '"' + self.path.rsplit('/', 1)[1] + '-tag"')
                self.end_headers()

        self.server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.url = f'http://127.0.0.1:{self.server.server_port}'
        self.caches = [self.url + '/' + name for name in ['official', 'community', 'numtide', 'ruby', 'own']]
        self.tmp = tempfile.TemporaryDirectory()
        self.outputs = Path(self.tmp.name) / 'outputs'
        self.outputs.write_text(ROOT + '\n')
        self.payload = b'fixture'
        self.metadata = {p: {'narHash': 'sha256-' + base64.b64encode(hashlib.sha256(b'fixture').digest()).decode(), 'narSize': 7, 'references': PATHS[1:] if p == ROOT else []} for p in PATHS}

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
        self.tmp.cleanup()

    def run_upload(self):
        def run(args, **kwargs):
            if args[:3] == ['nix', 'path-info', '--recursive']:
                return subprocess.CompletedProcess(args, 0, json.dumps(self.metadata))
            if args[:3] == ['nix', 'hash', 'convert']:
                return subprocess.CompletedProcess(args, 0, '0' * 52 + '\n')
            raise AssertionError(args)

        payload_file = Path(self.tmp.name) / 'payload'
        payload_file.write_bytes(self.payload)
        original_popen = subprocess.Popen
        with patch.dict(os.environ, {'CACHIX_AUTH_TOKEN': 'test-token'}), patch.object(uploader.subprocess, 'run', side_effect=run):
            def dump(args, **kwargs):
                self.assertEqual(args, ['nix-store', '--dump', ROOT])
                return original_popen([sys.executable, '-c', 'import sys; sys.stdout.buffer.write(open(sys.argv[1], "rb").read())', str(payload_file)], **kwargs)
            with patch.object(uploader.subprocess, 'Popen', side_effect=dump):
                uploader.publish('test-cache', self.outputs, self.caches, self.url)

    def test_uploads_only_missing_root_without_its_cached_references(self):
        self.run_upload()
        self.assertEqual([p for p, _, _ in self.posts], [
            '/api/v1/cache/test-cache/multipart-nar?compression=zst',
            '/api/v1/cache/test-cache/multipart-nar/test-nar?uploadId=upload%2Fid%2Btest%3D&partNumber=1',
            '/api/v1/cache/test-cache/multipart-nar/test-nar/complete?uploadId=upload%2Fid%2Btest%3D',
        ])
        self.assertEqual(len(self.puts), 1)
        _, compressed, headers = self.puts[0]
        self.assertEqual(zstd.decompress(compressed), b'fixture')
        self.assertEqual(headers['Content-Type'], 'application/octet-stream')
        self.assertEqual(headers['Content-Md5'], base64.b64encode(hashlib.md5(compressed).digest()).decode())
        self.assertNotIn('Authorization', headers)
        completion = json.loads(self.posts[2][1])
        self.assertEqual(completion['parts'], [{'partNumber': 1, 'eTag': '"part-1-tag"'}])
        metadata = completion['narInfoCreate']
        self.assertEqual(metadata['cReferences'], [p[11:] for p in PATHS[1:]])
        self.assertEqual(metadata['cStoreHash'], '0' * 32)
        self.assertEqual(metadata['cStoreSuffix'], 'system')
        self.assertTrue(all(auth == 'Bearer test-token' for _, _, auth in self.posts))

    def test_large_nar_uses_multiple_parts_and_completes_with_all_etags(self):
        self.payload = hashlib.shake_256(b'multipart-fixture').digest(33 * 1024 * 1024)
        self.metadata[ROOT]['narSize'] = len(self.payload)
        self.metadata[ROOT]['narHash'] = 'sha256-' + base64.b64encode(hashlib.sha256(self.payload).digest()).decode()
        self.run_upload()
        self.assertEqual(len(self.puts), 2)
        self.assertEqual(len(self.puts[0][1]), 32 * 1024 * 1024)
        packed = b''.join(body for _, body, _ in self.puts)
        self.assertEqual(zstd.decompress(packed), self.payload)
        completion = json.loads(self.posts[-1][1])
        self.assertEqual(completion['parts'], [
            {'partNumber': 1, 'eTag': '"part-1-tag"'},
            {'partNumber': 2, 'eTag': '"part-2-tag"'},
        ])
        self.assertEqual(completion['narInfoCreate']['cFileHash'], hashlib.sha256(packed).hexdigest())
        for _, body, headers in self.puts:
            self.assertEqual(headers['Content-Md5'], base64.b64encode(hashlib.md5(body).digest()).decode())
            self.assertNotIn('Authorization', headers)

    def test_lookup_failure_never_publishes_partial_closure(self):
        self.failure = 503
        with self.assertRaises(urllib.error.HTTPError) as raised:
            self.run_upload()
        raised.exception.close()
        self.assertEqual(self.posts, [])

    def test_upload_failure_is_not_success_and_does_not_register_narinfo(self):
        self.upload_failure = True
        with self.assertRaises(urllib.error.HTTPError) as raised:
            self.run_upload()
        raised.exception.close()
        self.assertEqual(len(self.puts), 1)
        self.assertTrue(self.posts[-1][0].startswith('/api/v1/cache/test-cache/multipart-nar/test-nar/abort?'))
        self.assertFalse(any('/complete?' in path for path, _, _ in self.posts))

    def test_fully_cached_closure_does_not_upload(self):
        self.metadata = {DEP: self.metadata[DEP]}
        self.run_upload()
        self.assertEqual(self.posts, [])

    def test_corrupt_export_is_rejected_before_upload(self):
        self.metadata[ROOT]['narSize'] = 123
        with self.assertRaises(ValueError):
            self.run_upload()
        self.assertEqual(self.posts, [])

    def test_invalid_or_empty_output_is_rejected(self):
        for content in ['', '/tmp/invalid\n']:
            self.outputs.write_text(content)
            with self.assertRaises(ValueError):
                self.run_upload()
        self.assertEqual(self.posts, [])


unittest.main()
