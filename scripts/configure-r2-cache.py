#!/usr/bin/env python3
import json
import getpass
from pathlib import Path
import re
import subprocess
import sys


def gh(kind, name, value):
    subprocess.run(['gh', kind, 'set', name, '--repo', 'shishi/nix-config'], input=value, text=True, check=True)


def main():
    signing_key = Path(sys.argv[1])
    if not signing_key.is_file():
        raise ValueError('指定した Nix 署名秘密鍵がありません。')
    with signing_key.open() as key:
        public = subprocess.check_output(['nix', 'key', 'convert-secret-to-public'], stdin=key, text=True).strip()
    config = json.loads(subprocess.check_output(['nix', 'eval', '--json', '--file', str(Path(__file__).resolve().parents[1] / 'shared/nix-caches.nix')], text=True))
    if public not in config['trustedPublicKeys']:
        raise ValueError('署名秘密鍵が設定の公開鍵と一致しません。')
    subprocess.run(['gh', 'auth', 'status'], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    endpoint = input('Cloudflare の S3 endpoint (https://...): ').strip().rstrip('/')
    if not re.fullmatch(r'https://[a-f0-9]{32}\.r2\.cloudflarestorage\.com', endpoint):
        raise ValueError('Cloudflare の標準 S3 endpoint を入力してください。')
    access_key = getpass.getpass('R2 Access Key ID (非表示): ').strip()
    secret_key = getpass.getpass('R2 Secret Access Key (非表示): ').strip()
    if not access_key or not secret_key:
        raise ValueError('R2 の認証情報が空です。')
    gh('secret', 'R2_ACCESS_KEY_ID', access_key)
    gh('secret', 'R2_SECRET_ACCESS_KEY', secret_key)
    gh('secret', 'NIX_CACHE_SIGNING_KEY', signing_key.read_text())
    gh('variable', 'R2_ENDPOINT', endpoint)
    gh('variable', 'R2_BUCKET', 'nix-config')
    gh('variable', 'R2_PUBLIC_URL', 'https://nix-cache.srevo.net')
    print('GitHub への登録が完了しました。R2 の接続確認を実行できます。')


if __name__ == '__main__':
    main()
