#!/usr/bin/env python3
import json
import os
from pathlib import Path
import subprocess
import uuid
import urllib.request

import boto3


def preflight():
    bucket = os.environ['R2_BUCKET']
    url = os.environ['R2_PUBLIC_URL'].rstrip('/')
    client = boto3.client('s3', endpoint_url=os.environ['R2_ENDPOINT'], region_name='auto')
    config = subprocess.check_output(['nix', 'eval', '--json', '--file', str(Path(__file__).resolve().parents[1] / 'shared/nix-caches.nix')], text=True)
    config = json.loads(config)
    if url not in config['substituters']:
        raise ValueError('R2_PUBLIC_URL does not match the declared substituters')
    with open(os.environ['NIX_SIGNING_KEY_FILE']) as key:
        public_key = subprocess.check_output(['nix', 'key', 'convert-secret-to-public'], stdin=key, text=True).strip()
    if public_key not in config['trustedPublicKeys']:
        raise ValueError('Signing key does not match the declared trusted public key')
    client.head_bucket(Bucket=bucket)
    probe = 'preflight/' + uuid.uuid4().hex
    body = uuid.uuid4().hex.encode()
    client.put_object(Bucket=bucket, Key=probe, Body=body, CacheControl='no-store')
    try:
        request = urllib.request.Request(url + '/' + probe, headers={'User-Agent': 'nix-config-cache/1.0'})
        with urllib.request.urlopen(request, timeout=30) as response:
            if response.read() != body:
                raise ValueError('Public endpoint did not return the uploaded probe')
    finally:
        client.delete_object(Bucket=bucket, Key=probe)
    client.put_object(Bucket=bucket, Key='nix-cache-info',
                      Body=b'StoreDir: /nix/store\nWantMassQuery: 1\nPriority: 50\n',
                      ContentType='text/x-nix-cache-info', CacheControl='no-cache')
    request = urllib.request.Request(url + '/nix-cache-info', headers={'User-Agent': 'nix-config-cache/1.0'})
    with urllib.request.urlopen(request, timeout=30) as response:
        if b'StoreDir: /nix/store\n' not in response.read():
            raise ValueError('Public nix-cache-info is invalid')
    print('R2 write/read/delete, public delivery and signing key checks passed')


if __name__ == '__main__':
    preflight()
