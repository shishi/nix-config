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


def head_sample(population, count):
    return list(population)[:count]


class FakeClient:
    def __init__(self, label_ids, items, *, unread=None):
        self.label_ids = label_ids
        self.items = {item["id"]: item for item in items}
        self.unread = unread

    def fetch_unread_ids(self, *, now=None):
        if self.unread is not None:
            return self.unread
        return [identifier for identifiers in self.label_ids.values() for identifier in identifiers]

    def fetch_label_ids(self, label, *, now=None):
        return self.label_ids.get(label, [])

    def fetch_contents(self, identifiers):
        return [self.items[identifier] for identifier in identifiers if identifier in self.items]


def article(identifier, title):
    return {"id": identifier, "title": title, "summary": {"content": f"Body of {title}"}}


class FreshRSSDigestTest(unittest.TestCase):
    def test_client_fetches_unread_ids_then_only_selected_contents(self):
        requests = []

        def opener(request, timeout):
            requests.append((request.get_method(), request.full_url, request.data))
            if request.full_url.endswith("/accounts/ClientLogin"):
                return FakeResponse(b"SID=x\nLSID=y\nAuth=token\n")
            if "/stream/items/ids?" in request.full_url:
                return FakeResponse(json.dumps({"itemRefs": [{"id": "22"}]}).encode())
            return FakeResponse(json.dumps({"items": []}).encode())

        client = freshrss_digest.FreshRSSClient(
            "https://rss.example.test",
            "shishi",
            "secret",
            opener=opener,
            sleep=lambda _seconds: None,
        )

        identifiers = client.fetch_unread_ids(now=1_800_000_000)
        self.assertEqual(identifiers, ["tag:google.com,2005:reader/item/0000000000000016"])
        client.fetch_label_ids("news", now=1_800_000_000)
        client.fetch_contents(identifiers)

        logins = [entry for entry in requests if entry[1].endswith("/accounts/ClientLogin")]
        self.assertEqual(len(logins), 1)
        unread_request = requests[1]
        self.assertIn("/reader/api/0/stream/items/ids?", unread_request[1])
        self.assertIn("s=user%2F-%2Fstate%2Fcom.google%2Freading-list", unread_request[1])
        self.assertIn("xt=user%2F-%2Fstate%2Fcom.google%2Fread", unread_request[1])
        self.assertIn(f"ot={1_800_000_000 - 7 * 24 * 60 * 60}", unread_request[1])
        label_request = requests[2]
        self.assertIn("s=user%2F-%2Flabel%2Fnews", label_request[1])
        # FreshRSS は label stream + xt で常に空を返すため、xt を付けてはいけない
        self.assertNotIn("xt=", label_request[1])
        contents_request = requests[3]
        self.assertIn("/reader/api/0/stream/items/contents", contents_request[1])
        self.assertIn(b"reader%2Fitem%2F0000000000000016", contents_request[2])

    def test_job_groups_by_label_and_deduplicates_across_runs(self):
        client = FakeClient(
            {"news": ["item-1"], "computer": ["item-2"]},
            [article("item-1", "First"), article("item-2", "Second")],
        )

        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            database = directory / "state.sqlite3"
            output = directory / "public" / "digest.atom"
            summarized = []

            def summarize(entry):
                summarized.append(entry["id"])
                return f"Summary for {entry['title']}"

            arguments = dict(now=1_800_000_000, sample=head_sample)
            first = freshrss_digest.run_job(
                client, ["news", "computer"], summarize, database, output, **arguments
            )
            second = freshrss_digest.run_job(
                client, ["news", "computer"], summarize, database, output, **arguments
            )

            self.assertTrue(first)
            self.assertFalse(second)
            self.assertEqual(summarized, ["item-1", "item-2"])

            root = ET.parse(output).getroot()
            namespace = {"atom": "http://www.w3.org/2005/Atom"}
            entries = root.findall("atom:entry", namespace)
            self.assertEqual(len(entries), 1)
            content = entries[0].find("atom:content", namespace).text
            self.assertIn("news — 直近7日の未読1件から1件を抽出", content)
            self.assertIn("computer — 直近7日の未読1件から1件を抽出", content)
            self.assertIn("Summary for Second", content)

    def test_summary_failure_stalls_the_batch(self):
        client = FakeClient({"news": ["item-1"]}, [article("item-1", "First")])

        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            database = directory / "state.sqlite3"
            output = directory / "public" / "digest.atom"

            def fail(_entry):
                raise RuntimeError("ollama unavailable")

            with self.assertRaisesRegex(RuntimeError, "ollama unavailable"):
                freshrss_digest.run_job(
                    client, ["news"], fail, database, output, now=1_800_000_000, sample=head_sample
                )

            self.assertFalse(output.exists())
            with sqlite3.connect(database) as connection:
                count = connection.execute("SELECT count(*) FROM processed_items").fetchone()[0]
            self.assertEqual(count, 0)

    def test_selection_caps_the_batch_and_retires_digest_entries(self):
        identifiers = ["digest-1"] + [f"item-{index}" for index in range(freshrss_digest.MAX_ITEMS + 5)]
        items = [
            {
                "id": "digest-1",
                "title": f"{freshrss_digest.DIGEST_TITLE_PREFIX}2026-09-01",
                "summary": {"content": "old digest"},
            }
        ] + [article(identifier, identifier) for identifier in identifiers[1:]]
        client = FakeClient({"news": identifiers}, items)

        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            database = directory / "state.sqlite3"
            summarized = []

            def summarize(entry):
                summarized.append(entry["id"])
                return "Summary"

            freshrss_digest.run_job(
                client,
                ["news"],
                summarize,
                database,
                directory / "public" / "digest.atom",
                now=1_800_000_000,
                sample=head_sample,
            )

            self.assertEqual(len(summarized), freshrss_digest.MAX_ITEMS - 1)
            self.assertNotIn("digest-1", summarized)
            with sqlite3.connect(database) as connection:
                retired = {
                    row[0] for row in connection.execute("SELECT id FROM processed_items")
                }
            self.assertIn("digest-1", retired)

    def test_deadline_publishes_finished_summaries_only(self):
        client = FakeClient(
            {"news": ["item-1", "item-2"]},
            [article("item-1", "First"), article("item-2", "Second")],
        )

        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            database = directory / "state.sqlite3"
            output = directory / "public" / "digest.atom"
            ticks = iter([0, 100])

            published = freshrss_digest.run_job(
                client,
                ["news"],
                lambda entry: f"Summary for {entry['title']}",
                database,
                output,
                now=1_800_000_000,
                deadline=50,
                clock=lambda: next(ticks),
                sample=head_sample,
            )

            self.assertTrue(published)
            content = ET.parse(output).getroot().find(
                "{http://www.w3.org/2005/Atom}entry/{http://www.w3.org/2005/Atom}content"
            ).text
            self.assertIn("Summary for First", content)
            self.assertNotIn("Summary for Second", content)
            with sqlite3.connect(database) as connection:
                retired = {row[0] for row in connection.execute("SELECT id FROM processed_items")}
            self.assertEqual(retired, {"item-1"})

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
