import http.server
import json
import os
import subprocess
import threading
import time
import urllib.request

ORIGIN = 'https://nix-cache.srevo.net'
PATH = '/nix/store/vd8ffgpbxx2j5wvzw45c086g1jzlis6m-unit-systemd-pstore.service'
KEY = 'nix-config-r2-1:0les2BkGLxYR8j0F3TazVPs2N0ki/SX9wb8Vdeny4+s='
print('Proxy variable presence:', {key: bool(value) for key, value in os.environ.items() if 'proxy' in key.lower()}, flush=True)
subprocess.run(['nix', '--version'], check=True)


def check(label, url, env):
    start = time.monotonic()
    try:
        result = subprocess.run(['nix', 'store', 'verify', '--store', url, '--sigs-needed', '1',
                                 '--option', 'trusted-public-keys', KEY, PATH],
                                env=env, capture_output=True, text=True, timeout=30)
        outcome = {'case': label, 'exit': result.returncode, 'stderr': result.stderr[-2500:]}
    except subprocess.TimeoutExpired as error:
        outcome = {'case': label, 'timeout': True, 'stderr': str(error.stderr)[-1500:]}
    outcome['seconds'] = round(time.monotonic() - start, 3)
    print(json.dumps(outcome), flush=True)


check('direct-r2', ORIGIN, os.environ.copy())
for bypass in [False, True]:
    requests = []
    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            requests.append(self.path)
            self.send_response(302)
            self.send_header('Location', ORIGIN + self.path)
            self.end_headers()
        do_HEAD = do_GET
        def log_message(self, *_):
            pass
    with http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler) as server:
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        url = f'http://127.0.0.1:{server.server_port}'
        env = os.environ.copy()
        if bypass:
            for key in ['no_proxy', 'NO_PROXY']:
                env[key] = ','.join(filter(None, [env.get(key), '127.0.0.1', 'localhost']))
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        try:
            with opener.open(urllib.request.Request(url + '/nix-cache-info', headers={'User-Agent': 'nix-config-cache/1.0'}), timeout=8) as response:
                print('Python direct local status:', response.status, flush=True)
        except Exception as error:
            print('Python direct local error:', type(error).__name__, flush=True)
        check('local-no-proxy' if bypass else 'local-default', url, env)
        print('Local handler requests:', requests, flush=True)
        server.shutdown()
        thread.join()
