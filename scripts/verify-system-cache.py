#!/usr/bin/env python3
import http.server
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import threading
import urllib.parse


def verify(outputs_file, closure_file, manifest_file):
    config = json.loads(subprocess.check_output([
        'nix', 'eval', '--json', '--file', str(Path(__file__).resolve().parents[1] / 'shared/nix-caches.nix')]))
    manifest = json.loads(Path(manifest_file).read_text())
    allowed = set(manifest['objects']) | {'nix-cache-info'}
    origin = config['ownSubstituter'].rstrip('/')
    outputs = Path(outputs_file).read_text().splitlines()
    if not outputs or outputs != manifest['outputs']:
        raise ValueError('Verification outputs do not match the generation manifest')

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            key = urllib.parse.urlsplit(self.path).path.removeprefix('/')
            if key not in allowed:
                self.send_error(404)
                return
            self.send_response(302)
            self.send_header('Location', origin + '/' + key)
            self.end_headers()

        do_HEAD = do_GET

        def log_message(self, *_):
            pass

    with http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler) as server:
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        sources = config['upstreamSubstituters'] + [f'http://127.0.0.1:{server.server_port}']
        root = tempfile.mkdtemp()
        store = 'local?root=' + root
        keys = ' '.join(config['trustedPublicKeys'])
        try:
            subprocess.run(['nix-store', '--store', store, '--realise', *outputs,
                            '--option', 'always-allow-substitutes', 'true',
                            '--option', 'require-sigs', 'true', '--option', 'max-jobs', '0',
                            '--option', 'builders', '', '--option', 'substituters', ' '.join(sources),
                            '--option', 'trusted-public-keys', keys], check=True)
            actual = subprocess.check_output(['nix', 'path-info', '--store', store, '--recursive', *outputs], text=True).splitlines()
            expected = Path(closure_file).read_text().splitlines()
            if sorted(actual) != sorted(expected):
                raise ValueError('Downloaded closure does not match the expected closure')
            subprocess.run(['nix', 'store', 'verify', '--store', store, '--all',
                            '--option', 'trusted-public-keys', keys], check=True)
        finally:
            subprocess.run(['chmod', '-R', 'u+w', root], check=True)
            shutil.rmtree(root)
            server.shutdown()
            thread.join()


if __name__ == '__main__':
    verify(*sys.argv[1:])
