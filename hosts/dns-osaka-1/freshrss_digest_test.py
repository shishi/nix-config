import json
import sqlite3
import tempfile
import unittest
import urllib.error
import xml.etree.ElementTree as ET
from pathlib import Path

import freshrss_digest


class FakeResponse:
    def __init__(self, body):
        self.body = body

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        return False

    def read(self):
        return self.body


class FreshRSSDigestTest(unittest.TestCase):
    def test_freshrss_client_only_logs_in_and_reads_the_stream(self):
        requests = []

        def opener(request, timeout):
            requests.append((request.get_method(), request.full_url, timeout))
            if request.full_url.endswith("/accounts/ClientLogin"):
                return FakeResponse(b"SID=x\nLSID=y\nAuth=token\n")

            return FakeResponse(json.dumps({"items": [{"id": f"item-{index}"} for index in range(101)]}).encode())

        client = freshrss_digest.FreshRSSClient(
            "https://rss.example.test",
            "shishi",
            "secret",
            opener=opener,
            sleep=lambda _seconds: None,
        )

        self.assertEqual(len(client.fetch_items(now=1_800_000_000)), 101)
        self.assertEqual(requests[0][0], "POST")
        self.assertTrue(requests[0][1].endswith("/api/greader.php/accounts/ClientLogin"))
        self.assertEqual(requests[1][0], "GET")
        self.assertIn("/api/greader.php/reader/api/0/stream/contents/reading-list?", requests[1][1])
        self.assertIn("n=10000", requests[1][1])
        self.assertIn(f"ot={1_800_000_000 - 7 * 24 * 60 * 60}", requests[1][1])
        self.assertNotIn("edit-tag", requests[1][1])

    def test_job_publishes_one_daily_entry_and_deduplicates_items(self):
        items = [
            {
                "id": "item-1",
                "title": "First",
                "canonical": [{"href": "https://example.test/first"}],
                "summary": {"content": "<p>First body</p>"},
            },
            {
                "id": "item-2",
                "title": "Second",
                "alternate": [{"href": "https://example.test/second"}],
                "content": {"content": "Second body"},
            },
        ]

        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            database = directory / "state.sqlite3"
            output = directory / "public" / "digest.atom"
            summarized = []

            def summarize(article):
                summarized.append(article["id"])
                return f"Summary for {article['title']}"

            first = freshrss_digest.run_job(
                items,
                summarize,
                database,
                output,
                now=1_800_000_000,
            )
            second = freshrss_digest.run_job(
                items,
                summarize,
                database,
                output,
                now=1_800_000_000,
            )

            self.assertTrue(first)
            self.assertFalse(second)
            self.assertEqual(summarized, ["item-1", "item-2"])

            root = ET.parse(output).getroot()
            namespace = {"atom": "http://www.w3.org/2005/Atom"}
            entries = root.findall("atom:entry", namespace)
            self.assertEqual(len(entries), 1)
            content = entries[0].find("atom:content", namespace).text
            self.assertIn("First", content)
            self.assertIn("Summary for Second", content)

            with sqlite3.connect(database) as connection:
                count = connection.execute("SELECT count(*) FROM processed_items").fetchone()[0]
            self.assertEqual(count, 2)

    def test_summary_failure_stalls_the_batch(self):
        items = [{"id": "item-1", "title": "First", "summary": {"content": "Body"}}]

        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            database = directory / "state.sqlite3"
            output = directory / "public" / "digest.atom"

            def fail(_article):
                raise RuntimeError("ollama unavailable")

            with self.assertRaisesRegex(RuntimeError, "ollama unavailable"):
                freshrss_digest.run_job(items, fail, database, output, now=1_800_000_000)

            self.assertFalse(output.exists())
            with sqlite3.connect(database) as connection:
                count = connection.execute("SELECT count(*) FROM processed_items").fetchone()[0]
            self.assertEqual(count, 0)

    def test_selection_skips_digest_entries_and_caps_the_batch(self):
        items = [
            {
                "id": "digest-1",
                "title": f"{freshrss_digest.DIGEST_TITLE_PREFIX}2026-09-01",
                "summary": {"content": "old digest"},
            }
        ] + [
            {
                "id": f"item-{index}",
                "title": f"Title {index}",
                "summary": {"content": "Body"},
            }
            for index in range(101)
        ]

        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            summarized = []

            def summarize(article):
                summarized.append(article["id"])
                return "Summary"

            freshrss_digest.run_job(
                items,
                summarize,
                directory / "state.sqlite3",
                directory / "public" / "digest.atom",
                now=1_800_000_000,
            )

            self.assertEqual(len(summarized), 100)
            self.assertNotIn("digest-1", summarized)

    def test_http_attempts_are_limited_to_three(self):
        attempts = 0

        def opener(_request, timeout):
            nonlocal attempts
            attempts += 1
            raise urllib.error.URLError("offline")

        with self.assertRaises(urllib.error.URLError):
            freshrss_digest.open_with_retries(
                freshrss_digest.urllib.request.Request("https://example.test"),
                opener=opener,
                sleep=lambda _seconds: None,
            )

        self.assertEqual(attempts, 3)


if __name__ == "__main__":
    unittest.main()
