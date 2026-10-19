import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(sys.argv.pop(1)) if len(sys.argv) > 1 else Path(__file__).with_name("readest-init.py")
URL_KEYS = {
    "HOST_IP", "API_EXTERNAL_URL", "SITE_URL", "SUPABASE_PUBLIC_URL",
    "S3_PUBLIC_ENDPOINT", "ADDITIONAL_REDIRECT_URLS",
}


class ReadestInitializationTest(unittest.TestCase):
    def run_initializer(self, destination, origin):
        result = subprocess.run(
            [sys.executable, str(SCRIPT), str(destination), origin],
            check=True, capture_output=True,
        )
        self.assertEqual(result.stdout, b"")
        self.assertEqual(result.stderr, b"")

    def test_fresh_initialization_and_repeat_preserve_credentials(self):
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / ".env"
            self.run_initializer(destination, "https://readest.example.test")
            original = destination.read_bytes()
            self.assertEqual(os.stat(destination).st_mode & 0o777, 0o600)
            self.assertIn(b"SITE_URL='https://readest.example.test'\n", original)
            self.run_initializer(destination, "https://readest.example.test")
            self.assertEqual(destination.read_bytes(), original)

    def test_origin_migration_preserves_all_other_settings(self):
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / ".env"
            self.run_initializer(destination, "https://previous.example.test")
            with destination.open("a") as output:
                output.write("# Operator settings\nCUSTOM_SETTING='keep this value'\n")
            original = destination.read_text().splitlines()
            self.run_initializer(destination, "https://readest.example.test")
            updated = destination.read_text().splitlines()
            self.assertEqual(
                [line for line in original if line.split("=", 1)[0] not in URL_KEYS],
                [line for line in updated if line.split("=", 1)[0] not in URL_KEYS],
            )
            values = dict(line.split("=", 1) for line in updated if "=" in line)
            for name in URL_KEYS - {"HOST_IP", "ADDITIONAL_REDIRECT_URLS"}:
                self.assertEqual(values[name], "'https://readest.example.test'")
            self.assertEqual(values["HOST_IP"], "'readest.example.test'")
            self.assertEqual(values["ADDITIONAL_REDIRECT_URLS"], "'https://readest.example.test/**'")
            self.assertEqual(os.stat(destination).st_mode & 0o777, 0o600)


if __name__ == "__main__":
    unittest.main()
