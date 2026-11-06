#!/usr/bin/env python3
import base64
import concurrent.futures
import hashlib
import json
import lzma
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request

STORE_PATH = re.compile(r'/nix/store/[0-9a-z]{32}-[^/\s]+')


def nix_json(*args):
    return json.loads(subprocess.run(['nix', *args], check=True, text=True, stdout=subprocess.PIPE).stdout)


def available(source, path):
    url = source.rstrip('/') + '/' + path[11:43] + '.narinfo'
    try:
        request = urllib.request.Request(url, headers={'User-Agent': 'nix-config-cache/1.0'})
        with urllib.request.urlopen(request, timeout=30) as response:
            narinfo = response.read().decode()
        if f'StorePath: {path}' not in narinfo.splitlines():
            raise ValueError(f'Unexpected StorePath from {url}')
        return True
    except urllib.error.HTTPError as error:
        error.close()
        if error.code == 404:
            return False
        raise


def upload(cache, path, info, api, token):
    base = f'{api}/api/v1/cache/{cache}'
    headers = {'Authorization': f'Bearer {token}', 'User-Agent': 'nix-config-cache/1.0'}
    with tempfile.TemporaryFile() as compressed:
        digest = hashlib.sha256()
        raw_digest = hashlib.sha256()
        raw_size = 0
        compressor = lzma.LZMACompressor(preset=2)
        with subprocess.Popen(['nix-store', '--dump', path], stdout=subprocess.PIPE) as process:
            while chunk := process.stdout.read(1024 * 1024):
                raw_digest.update(chunk)
                raw_size += len(chunk)
                packed = compressor.compress(chunk)
                compressed.write(packed)
                digest.update(packed)
            packed = compressor.flush()
            compressed.write(packed)
            digest.update(packed)
            if process.wait() != 0:
                raise RuntimeError(f'NAR export failed: {path}')
        if raw_size != info["narSize"] or "sha256-" + base64.b64encode(raw_digest.digest()).decode() != info["narHash"]:
            raise ValueError(f"NAR export does not match store metadata: {path}")
        size = compressed.tell()
        compressed.seek(0)
        request = urllib.request.Request(
            base + '/nar?compression=xz', data=compressed, method='POST',
            headers={**headers, 'Content-Type': 'application/octet-stream', 'Content-Length': str(size)},
        )
        with urllib.request.urlopen(request, timeout=300) as response:
            response.read()
    nar_hash = subprocess.run(
        ['nix', 'hash', 'convert', '--hash-algo', 'sha256', '--to', 'nix32', info['narHash']],
        check=True, text=True, stdout=subprocess.PIPE,
    ).stdout.strip()
    store_hash, suffix = path[11:].split('-', 1)
    metadata = {
        'cStoreHash': store_hash, 'cStoreSuffix': suffix,
        'cNarHash': 'sha256:' + nar_hash, 'cNarSize': info['narSize'],
        'cFileHash': digest.hexdigest(), 'cFileSize': size,
        'cReferences': [p[11:] for p in info['references']],
        'cDeriver': 'unknown-deriver', 'cSig': None,
    }
    request = urllib.request.Request(
        base + '/' + store_hash + '.narinfo', data=json.dumps(metadata).encode(), method='POST',
        headers={**headers, 'Content-Type': 'application/json'},
    )
    with urllib.request.urlopen(request, timeout=60) as response:
        response.read()
    print(f'Uploaded {path}', flush=True)


def publish(cache, outputs_file, sources, api='https://api.cachix.org'):
    if not re.fullmatch(r'[a-z0-9][a-z0-9-]*', cache):
        raise ValueError('Invalid Cachix cache name')
    outputs = Path(outputs_file).read_text().splitlines()
    if not outputs or any(not STORE_PATH.fullmatch(p) for p in outputs):
        raise ValueError('Expected a nonempty list of store paths')
    if not sources:
        raise ValueError('No substituters configured')
    closure = nix_json('path-info', '--recursive', '--json', *outputs)
    if not closure or any(not STORE_PATH.fullmatch(p) for p in closure):
        raise ValueError('Invalid or empty closure')
    print(f'Checking {len(closure)} paths against {len(sources)} caches', flush=True)

    def missing(path):
        return not any(available(source, path) for source in sources)

    # Complete every lookup before publishing: errors must not turn into misses.
    with concurrent.futures.ThreadPoolExecutor(max_workers=16) as pool:
        absent = [p for p, absent in zip(closure, pool.map(missing, closure)) if absent]
    print(f'{len(absent)} paths are missing from all configured caches', flush=True)
    token = os.environ.get('CACHIX_AUTH_TOKEN')
    if absent and not token:
        raise ValueError('CACHIX_AUTH_TOKEN is required')
    # The CLI's push expands closures again; the NAR API publishes exactly these paths.
    # https://github.com/cachix/cachix/blob/master/cachix-api/src/Cachix/API.hs
    for path in absent:
        upload(cache, path, closure[path], api, token)


if __name__ == '__main__':
    try:
        sources = nix_json('eval', '--json', '--file', str(Path(__file__).resolve().parents[1] / 'shared/nix-caches.nix'), '--apply', 'x: x.substituters')
        publish(sys.argv[1], sys.argv[2], sources)
    except Exception as error:
        print(f'Cache publication failed: {error}', file=sys.stderr)
        sys.exit(1)
