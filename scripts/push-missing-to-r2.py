#!/usr/bin/env python3
import argparse
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

    def source_for(path):
        return next((source for source in sources if available(source, path)), None)

    # Complete every lookup before publishing: errors must not turn into misses.
    with concurrent.futures.ThreadPoolExecutor(max_workers=16) as pool:
        found = list(pool.map(source_for, closure))
    absent = [path for path, source in zip(closure, found) if source is None]
    required = [path for path, source in zip(closure, found) if source is None or source == sources[-1]]
    print(f'{len(absent)} paths are missing from all configured caches', flush=True)
    for path in absent:
        upload(bucket, path, closure[path], client, key_file)
    return outputs, required


NAR_OBJECT = re.compile(r'nar/[0-9a-f]{64}\.nar\.zst')
INFO_OBJECT = re.compile(r'[0-9a-z]{32}\.narinfo')


def generation_manifest(bucket, outputs, required, client):
    objects = set()
    for path in required:
        key = path[11:43] + '.narinfo'
        response = client.get_object(Bucket=bucket, Key=key)
        with response['Body'] as stream:
            lines = stream.read().decode().splitlines()
        if f'StorePath: {path}' not in lines:
            raise ValueError(f'Unexpected store path in {key}')
        urls = [line[5:] for line in lines if line.startswith('URL: ')]
        if len(urls) != 1 or not NAR_OBJECT.fullmatch(urls[0]):
            raise ValueError(f'Unexpected NAR object in {key}')
        objects.update([key, urls[0]])
    return {'version': 1, 'outputs': outputs, 'objects': sorted(objects)}


def prune(bucket, manifest_file, client):
    manifest = json.loads(Path(manifest_file).read_text())
    outputs = manifest.get('outputs')
    objects = manifest.get('objects')
    if (manifest.get('version') != 1 or not isinstance(outputs, list) or not outputs
            or any(not isinstance(path, str) or not STORE_PATH.fullmatch(path) for path in outputs)
            or not isinstance(objects, list)
            or any(not isinstance(key, str) or not (NAR_OBJECT.fullmatch(key) or INFO_OBJECT.fullmatch(key)) for key in objects)):
        raise ValueError('Invalid generation manifest')
    keep = set(objects)

    def inventory():
        return {item['Key']
                for page in client.get_paginator('list_objects_v2').paginate(Bucket=bucket)
                for item in page.get('Contents', [])
                if NAR_OBJECT.fullmatch(item['Key']) or INFO_OBJECT.fullmatch(item['Key'])}

    present = inventory()
    if not keep.issubset(present):
        raise ValueError('Current generation objects are missing; refusing to prune')
    obsolete = present - keep
    # Remove metadata before its NAR so old entries cannot advertise deleted data.
    for group in [sorted(key for key in obsolete if INFO_OBJECT.fullmatch(key)),
                  sorted(key for key in obsolete if NAR_OBJECT.fullmatch(key))]:
        for offset in range(0, len(group), 1000):
            result = client.delete_objects(Bucket=bucket, Delete={
                'Objects': [{'Key': key} for key in group[offset:offset + 1000]], 'Quiet': True})
            if result.get('Errors'):
                raise RuntimeError('R2 did not delete every obsolete object')
    if inventory() != keep:
        raise ValueError('R2 inventory does not match the single current generation')
    print(f'Retained one generation: {len(keep)} objects; removed {len(obsolete)} obsolete objects', flush=True)


if __name__ == '__main__':
    try:
        import boto3
        parser = argparse.ArgumentParser()
        commands = parser.add_subparsers(dest='command', required=True)
        publish_parser = commands.add_parser('publish')
        publish_parser.add_argument('outputs')
        publish_parser.add_argument('manifest')
        prune_parser = commands.add_parser('prune')
        prune_parser.add_argument('manifest')
        args = parser.parse_args()
        client = boto3.client('s3', endpoint_url=os.environ['R2_ENDPOINT'], region_name='auto')
        if args.command == 'publish':
            sources = nix_json('eval', '--json', '--file', str(Path(__file__).resolve().parents[1] / 'shared/nix-caches.nix'), '--apply', 'x: x.upstreamSubstituters')
            sources.append(os.environ['R2_PUBLIC_URL'])
            outputs, required = publish(os.environ['R2_BUCKET'], args.outputs, sources, client, os.environ['NIX_SIGNING_KEY_FILE'])
            manifest = generation_manifest(os.environ['R2_BUCKET'], outputs, required, client)
            Path(args.manifest).write_text(json.dumps(manifest))
        else:
            prune(os.environ['R2_BUCKET'], args.manifest, client)
    except Exception as error:
        print(f'Cache publication failed: {error}', file=sys.stderr)
        sys.exit(1)
