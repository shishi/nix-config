#!/usr/bin/env python3
import base64
import concurrent.futures
import hashlib
import json
from compression import zstd
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


def upload(bucket, path, info, client, key_file):
    subprocess.run(['nix', 'store', 'sign', '--key-file', str(key_file), path], check=True)
    signatures = nix_json('path-info', '--json', path)[path].get('signatures', [])
    key_name = Path(key_file).read_text().split(':', 1)[0]
    signatures = [sig for sig in signatures if sig.startswith(key_name + ':')]
    if not signatures:
        raise ValueError(f'Missing cache signature: {path}')
    print(f'Uploading {path} ({info["narSize"]} NAR bytes)', flush=True)
    with tempfile.TemporaryFile() as compressed:
        digest = hashlib.sha256()
        raw_digest = hashlib.sha256()
        raw_size = 0
        compressor = zstd.ZstdCompressor(level=8)
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
        object_key = 'nar/' + digest.hexdigest() + '.nar.zst'
        client.upload_fileobj(compressed, bucket, object_key, ExtraArgs={
            'ContentType': 'application/x-nix-nar',
            'CacheControl': 'public, max-age=31536000, immutable',
        })
        fields = [
            f'StorePath: {path}', f'URL: {object_key}', 'Compression: zstd',
            'FileHash: sha256:' + digest.hexdigest(), f'FileSize: {size}',
            f'NarHash: {info["narHash"]}', f'NarSize: {info["narSize"]}',
            'References: ' + ' '.join(sorted(p[11:] for p in info['references'])),
        ]
        fields.extend('Sig: ' + signature for signature in signatures)
        client.put_object(Bucket=bucket, Key=path[11:43] + '.narinfo',
                          Body=('\n'.join(fields) + '\n').encode(),
                          ContentType='text/x-nix-narinfo', CacheControl='no-cache')
    print(f'Uploaded {path}', flush=True)


def publish(bucket, outputs_file, sources, client, key_file):
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
    for path in absent:
        upload(bucket, path, closure[path], client, key_file)


if __name__ == '__main__':
    try:
        import boto3
        sources = nix_json('eval', '--json', '--file', str(Path(__file__).resolve().parents[1] / 'shared/nix-caches.nix'), '--apply', 'x: x.upstreamSubstituters')
        sources.append(os.environ['R2_PUBLIC_URL'])
        client = boto3.client('s3', endpoint_url=os.environ['R2_ENDPOINT'], region_name='auto')
        publish(os.environ['R2_BUCKET'], sys.argv[1], sources, client, os.environ['NIX_SIGNING_KEY_FILE'])
    except Exception as error:
        print(f'Cache publication failed: {error}', file=sys.stderr)
        sys.exit(1)
