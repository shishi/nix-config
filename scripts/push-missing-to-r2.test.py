import base64
import hashlib
from compression import zstd
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('uploader', sys.argv.pop(1))
uploader = importlib.util.module_from_spec(spec)
spec.loader.exec_module(uploader)
ROOT = '/nix/store/' + '0' * 32 + '-system'
PATHS = [ROOT] + ['/nix/store/' + str(i) * 32 + '-dependency' for i in range(1, 6)]

class PublicationTest(unittest.TestCase):
    def test_publishes_only_missing_despite_external_references(self):
        with tempfile.TemporaryDirectory() as directory:
            outputs = Path(directory) / 'outputs'
            outputs.write_text(ROOT + '\n')
            closure = {p: {'narHash': 'sha256-test', 'narSize': 1, 'references': PATHS[1:]} for p in PATHS}
            sources = ['official', 'community', 'numtide', 'ruby', 'own']
            with patch.object(uploader, 'nix_json', return_value=closure), patch.object(uploader, 'available', side_effect=lambda source, path: path != ROOT and sources.index(source) == PATHS.index(path)-1), patch.object(uploader, 'upload') as upload:
                uploader.publish('cache', outputs, sources, object(), 'key')
            self.assertEqual([call.args[1] for call in upload.call_args_list], [ROOT])

    def test_lookup_error_prevents_every_write(self):
        with tempfile.TemporaryDirectory() as directory:
            outputs = Path(directory) / 'outputs'
            outputs.write_text(ROOT + '\n')
            with patch.object(uploader, 'nix_json', return_value={ROOT: {}}), patch.object(uploader, 'available', side_effect=RuntimeError('503')), patch.object(uploader, 'upload') as upload:
                with self.assertRaisesRegex(RuntimeError, '503'):
                    uploader.publish('cache', outputs, ['upstream'], object(), 'key')
            upload.assert_not_called()

class ObjectUploadTest(unittest.TestCase):
    def exercise(self, fail=False, corrupt=False):
        raw = b'test NAR bytes'
        info = {'narHash': 'sha256-' + base64.b64encode(hashlib.sha256(raw).digest()).decode(),
                'narSize': len(raw) + int(corrupt), 'references': PATHS[1:]}
        writes = []
        class Client:
            def upload_fileobj(self, stream, bucket, key, **kwargs):
                if fail:
                    raise RuntimeError('upload failed')
                writes.append((key, stream.read()))
            def put_object(self, **kwargs):
                writes.append((kwargs['Key'], kwargs['Body']))
        process = unittest.mock.MagicMock()
        process.stdout = io.BytesIO(raw)
        process.wait.return_value = 0
        process.__enter__.return_value = process
        with tempfile.TemporaryDirectory() as directory:
            key_file = Path(directory) / 'key'
            key_file.write_text('test-key:private')
            with patch.object(uploader.subprocess, 'run'), patch.object(uploader.subprocess, 'Popen', return_value=process), patch.object(uploader, 'nix_json', return_value={ROOT: {'signatures': ['test-key:signature', 'other:signature']}}):
                if fail or corrupt:
                    with self.assertRaises((RuntimeError, ValueError)):
                        uploader.upload('bucket', ROOT, info, Client(), key_file)
                else:
                    uploader.upload('bucket', ROOT, info, Client(), key_file)
        return raw, writes

    def test_signed_metadata_follows_complete_nar_with_external_references(self):
        raw, writes = self.exercise()
        self.assertEqual(len(writes), 2)
        self.assertEqual(zstd.decompress(writes[0][1]), raw)
        metadata = writes[1][1].decode()
        self.assertIn('URL: ' + writes[0][0] + '\n', metadata)
        self.assertIn('FileHash: sha256:' + hashlib.sha256(writes[0][1]).hexdigest(), metadata)
        self.assertIn('References: ' + ' '.join(p[11:] for p in PATHS[1:]), metadata)
        self.assertIn('Sig: test-key:signature', metadata)
        self.assertNotIn('other:signature', metadata)
        self.assertEqual(writes[1][0], ROOT[11:43] + '.narinfo')

    def test_nar_upload_failure_never_publishes_metadata(self):
        self.assertEqual(self.exercise(fail=True)[1], [])

    def test_store_metadata_mismatch_prevents_every_write(self):
        self.assertEqual(self.exercise(corrupt=True)[1], [])

class ManifestTest(unittest.TestCase):
    def test_current_metadata_produces_prune_keep_set(self):
        nar = 'nar/' + 'a' * 64 + '.nar.zst'
        body = f'StorePath: {ROOT}\nURL: {nar}\n'.encode()
        client = unittest.mock.MagicMock()
        client.get_object.return_value = {'Body': io.BytesIO(body)}
        manifest = uploader.generation_manifest('bucket', [ROOT], [ROOT], client)
        self.assertEqual(manifest, {'version': 1, 'outputs': [ROOT], 'objects': sorted([ROOT[11:43] + '.narinfo', nar])})

class RetentionTest(unittest.TestCase):
    def test_keeps_one_generation_and_shared_nar(self):
        current_info = '0' * 32 + '.narinfo'
        old_info = '1' * 32 + '.narinfo'
        shared_nar = 'nar/' + 'a' * 64 + '.nar.zst'
        old_nar = 'nar/' + 'b' * 64 + '.nar.zst'
        keys = {current_info, old_info, shared_nar, old_nar, 'nix-cache-info', 'unrelated/file'}
        deleted = []
        class Client:
            def get_paginator(self, name):
                return self
            def paginate(self, **kwargs):
                return [{'Contents': [{'Key': key} for key in sorted(keys)]}]
            def delete_objects(self, **kwargs):
                batch = [item['Key'] for item in kwargs['Delete']['Objects']]
                deleted.extend(batch)
                keys.difference_update(batch)
                return {}
            def put_object(self, **kwargs):
                keys.add(kwargs['Key'])
        with tempfile.TemporaryDirectory() as directory:
            manifest = Path(directory) / 'generation.json'
            manifest.write_text(json.dumps({'version': 1, 'outputs': [ROOT], 'objects': [current_info, shared_nar]}))
            uploader.prune('bucket', manifest, Client())
        self.assertEqual(deleted, [old_info, old_nar])
        self.assertEqual(keys, {current_info, shared_nar, 'nix-cache-info', 'unrelated/file'})

    def test_invalid_manifest_never_deletes(self):
        client = unittest.mock.MagicMock()
        with tempfile.TemporaryDirectory() as directory:
            manifest = Path(directory) / 'generation.json'
            manifest.write_text(json.dumps({'version': 1, 'outputs': [], 'objects': []}))
            with self.assertRaises(ValueError):
                uploader.prune('bucket', manifest, client)
        client.delete_objects.assert_not_called()

if __name__ == '__main__':
    unittest.main()
