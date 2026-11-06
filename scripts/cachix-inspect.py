#!/usr/bin/env python3
import json
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
    return result


if __name__ == '__main__':
    payload = json.dumps(collect()).encode()
    encrypted = subprocess.run(['age', '--armor', '--recipient', os.environ['INSPECTION_RECIPIENT']], input=payload, check=True, stdout=subprocess.PIPE).stdout
    sys.stdout.buffer.write(encrypted)
