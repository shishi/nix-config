#!/usr/bin/env python3
import json
from datetime import datetime
from pathlib import Path
import os
import subprocess
import sys
import urllib.error
import urllib.request


def collect():
    result = {}
    headers = {'Authorization': 'Bearer ' + os.environ['CACHIX_AUTH_TOKEN'], 'User-Agent': 'nix-config-inspection/1.0', 'Accept': 'application/json'}

    def get(path):
        try:
            request = urllib.request.Request('https://app.cachix.org/api/v1/' + path, headers=headers)
            with urllib.request.urlopen(request, timeout=20) as response:
                return {'status': response.status, 'data': json.load(response)}
        except urllib.error.HTTPError as error:
            error.close()
            return {'status': error.code}
        except Exception as error:
            return {'errorType': type(error).__name__}

    user = get('user')
    result['accountStatus'] = user.get('status', user.get('errorType'))
    data = user.get('data', {})
    result['capacity'] = {key: data.get(key) for key in ['subscriptionStorageUsage', 'subscriptionStorageLimit']}
    evidence = json.loads(Path(__file__).with_name('cachix-required-evidence.json').read_text())
    if isinstance(data.get('id'), int):
        gc = get('garbage-collection/info/' + str(data['id']) + '?limit=1000')
        result['gcStatus'] = gc.get('status', gc.get('errorType'))
        history = gc.get('data', {}).get('history')
        if isinstance(history, list):
            matched = []
            after = []
            invalid = 0
            for row in history:
                cache = str(row.get('binaryCache', '')).removeprefix('https://').strip('/').removesuffix('.cachix.org')
                store_hash = str(row.get('storePath', '')).rsplit('/', 1)[-1].split('-', 1)[0]
                if cache != 'nix-config-shishi' or store_hash not in evidence or not row.get('deletedOn'):
                    continue
                matched.append(row)
                try:
                    deleted = datetime.fromisoformat(row['deletedOn'].replace('Z', '+00:00'))
                    observed = datetime.fromisoformat(evidence[store_hash].replace('Z', '+00:00'))
                    if observed <= deleted <= datetime.fromisoformat('2026-11-06T17:00:30.866572+00:00'):
                        after.append(row)
                except (TypeError, ValueError):
                    invalid += 1
            result['retention'] = {
                'requiredPaths': len(evidence), 'historyRowsRead': len(history),
                'targetCacheHistoryRows': sum(str(r.get('binaryCache', '')).removeprefix('https://').strip('/').removesuffix('.cachix.org') == 'nix-config-shishi' for r in history),
                'historyReachedRequestedLimit': len(history) >= 1000,
                'requiredPathsInRetrievedHistory': len({r['storePath'] for r in matched}),
                'requiredPathsDeletedBetweenUploadAndFailure': len({r['storePath'] for r in after}),
                'compressedBytesDeletedBetweenUploadAndFailure': sum(r.get('fileSize', 0) for r in after),
                'invalidMatchingTimestamps': invalid,
            }
    return result


if __name__ == '__main__':
    payload = json.dumps(collect()).encode()
    encrypted = subprocess.run(['age', '--armor', '--recipient', os.environ['INSPECTION_RECIPIENT']], input=payload, check=True, stdout=subprocess.PIPE).stdout
    sys.stdout.buffer.write(encrypted)
