#!/usr/bin/env python3

import datetime
import html
import json
import os
import random
import sqlite3
import tempfile
import time
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from html.parser import HTMLParser
from pathlib import Path
from zoneinfo import ZoneInfo


ATOM_NAMESPACE = "http://www.w3.org/2005/Atom"
DIGEST_TITLE_PREFIX = "AI digest — "
MAX_ATTEMPTS = 3
# この箱の Ollama は読み込み毎秒約 9 トークン(実測)。本文 3,000 字 × 20 件が
# 90 分の時間予算に収まるラインで、超過分は打ち切って要約済み分だけ公開する。
MAX_ITEMS = 20
MAX_ARTICLE_CHARS = 3_000
TIME_BUDGET_SECONDS = 90 * 60
FETCH_LIMIT = 10_000
WINDOW_HOURS = 24


class TextExtractor(HTMLParser):
    def __init__(self):
        super().__init__()
        self.parts = []

    def handle_data(self, data):
        if data.strip():
            self.parts.append(data.strip())


def html_to_text(value):
    parser = TextExtractor()
    parser.feed(value or "")
    return "\n".join(parser.parts)


def open_with_retries(request, *, opener=urllib.request.urlopen, sleep=time.sleep, timeout=30):
    for attempt in range(MAX_ATTEMPTS):
        try:
            with opener(request, timeout=timeout) as response:
                return response.read()
        except (OSError, TimeoutError):
            if attempt == MAX_ATTEMPTS - 1:
                raise
            sleep(2 ** attempt)


def item_tag_id(reference_id):
    return f"tag:google.com,2005:reader/item/{int(reference_id):016x}"


class FreshRSSClient:
    def __init__(self, base_url, username, password, *, opener=urllib.request.urlopen, sleep=time.sleep):
        self.base_url = base_url.rstrip("/")
        self.username = username
        self.password = password
        self.opener = opener
        self.sleep = sleep
        self._token = None

    def request(self, request):
        return open_with_retries(request, opener=self.opener, sleep=self.sleep)

    def login(self):
        body = urllib.parse.urlencode(
            {
                "Email": self.username,
                "Passwd": self.password,
                "service": "reader",
                "accountType": "HOSTED_OR_GOOGLE",
                "source": "dns-osaka-1-freshrss-digest",
            }
        ).encode()
        request = urllib.request.Request(
            f"{self.base_url}/api/greader.php/accounts/ClientLogin",
            data=body,
            headers={"Content-Type": "application/x-www-form-urlencoded"},
        )
        response = self.request(request).decode()
        fields = dict(line.split("=", 1) for line in response.splitlines() if "=" in line)
        if not fields.get("Auth"):
            raise RuntimeError("FreshRSS ClientLogin did not return Auth")
        return fields["Auth"]

    def token(self):
        if self._token is None:
            self._token = self.login()
        return self._token

    def fetch_label_ids(self, label, *, now=None):
        now = time.time() if now is None else now
        query = urllib.parse.urlencode(
            {
                "output": "json",
                "s": f"user/-/label/{label}",
                "n": FETCH_LIMIT,
                "ot": int(now - WINDOW_HOURS * 60 * 60),
            }
        )
        request = urllib.request.Request(
            f"{self.base_url}/api/greader.php/reader/api/0/stream/items/ids?{query}",
            headers={"Authorization": f"GoogleLogin auth={self.token()}"},
        )
        payload = json.loads(self.request(request))
        return [item_tag_id(reference["id"]) for reference in payload.get("itemRefs", [])]

    def fetch_contents(self, identifiers):
        body = urllib.parse.urlencode([("i", identifier) for identifier in identifiers]).encode()
        request = urllib.request.Request(
            f"{self.base_url}/api/greader.php/reader/api/0/stream/items/contents?output=json",
            data=body,
            headers={
                "Authorization": f"GoogleLogin auth={self.token()}",
                "Content-Type": "application/x-www-form-urlencoded",
            },
        )
        payload = json.loads(self.request(request))
        return payload.get("items", [])


class OllamaClient:
    def __init__(self, base_url, model, *, opener=urllib.request.urlopen, sleep=time.sleep):
        self.endpoint = f"{base_url.rstrip('/')}/api/generate"
        self.model = model
        self.opener = opener
        self.sleep = sleep

    def summarize(self, article):
        prompt = (
            "次の記事を日本語で2〜3文に要約してください。事実だけを書き、前置きや箇条書きは不要です。\n\n"
            f"タイトル: {article['title']}\n"
            f"URL: {article['url']}\n"
            f"本文:\n{article['body'][:MAX_ARTICLE_CHARS]}"
        )
        data = json.dumps(
            {
                "model": self.model,
                "prompt": prompt,
                "stream": False,
                "keep_alive": -1,
                "options": {"num_ctx": 8192},
            },
            ensure_ascii=False,
        ).encode()
        request = urllib.request.Request(
            self.endpoint,
            data=data,
            headers={"Content-Type": "application/json"},
        )
        payload = json.loads(
            open_with_retries(
                request,
                opener=self.opener,
                sleep=self.sleep,
                timeout=600,
            )
        )
        summary = payload.get("response", "").strip()
        if not summary:
            raise RuntimeError("Ollama returned an empty summary")
        return summary


def item_url(item):
    for key in ("canonical", "alternate"):
        for candidate in item.get(key, []):
            if candidate.get("href"):
                return candidate["href"]
    return item.get("origin", {}).get("htmlUrl", "")


def normalize_item(item):
    identifier = item.get("id")
    title = item.get("title", "").strip()
    if not identifier or title.startswith(DIGEST_TITLE_PREFIX):
        return None
    raw_body = item.get("content", {}).get("content") or item.get("summary", {}).get("content", "")
    return {
        "id": identifier,
        "title": title or "(untitled)",
        "url": item_url(item),
        "body": html_to_text(raw_body),
    }


def initialize_database(database):
    database.parent.mkdir(parents=True, exist_ok=True)
    with sqlite3.connect(database) as connection:
        connection.executescript(
            """
            CREATE TABLE IF NOT EXISTS processed_items (
                id TEXT PRIMARY KEY,
                processed_at TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS digests (
                id TEXT PRIMARY KEY,
                updated_at TEXT NOT NULL,
                title TEXT NOT NULL,
                content_html TEXT NOT NULL
            );
            """
        )


def digest_content(sections):
    parts = []
    for label, total_in_window, summaries in sections:
        if not summaries:
            continue
        heading = html.escape(f"{label} — 直近24時間の{total_in_window}件から{len(summaries)}件を抽出")
        parts.append(f"<h2>{heading}</h2>")
        for article, summary in summaries:
            title = html.escape(article["title"])
            url = html.escape(article["url"], quote=True)
            article_heading = f'<h3><a href="{url}">{title}</a></h3>' if url else f"<h3>{title}</h3>"
            parts.append(f"<article>{article_heading}<p>{html.escape(summary)}</p></article>")
    return "\n".join(parts)


def write_feed(connection, output):
    ET.register_namespace("", ATOM_NAMESPACE)
    feed = ET.Element(f"{{{ATOM_NAMESPACE}}}feed")
    ET.SubElement(feed, f"{{{ATOM_NAMESPACE}}}id").text = "urn:shishi:freshrss-digest"
    ET.SubElement(feed, f"{{{ATOM_NAMESPACE}}}title").text = "FreshRSS AI digest"
    rows = connection.execute(
        "SELECT id, updated_at, title, content_html FROM digests ORDER BY updated_at DESC LIMIT 7"
    ).fetchall()
    ET.SubElement(feed, f"{{{ATOM_NAMESPACE}}}updated").text = rows[0][1]
    for identifier, updated_at, title, content_html in rows:
        entry = ET.SubElement(feed, f"{{{ATOM_NAMESPACE}}}entry")
        ET.SubElement(entry, f"{{{ATOM_NAMESPACE}}}id").text = identifier
        ET.SubElement(entry, f"{{{ATOM_NAMESPACE}}}updated").text = updated_at
        ET.SubElement(entry, f"{{{ATOM_NAMESPACE}}}title").text = title
        ET.SubElement(entry, f"{{{ATOM_NAMESPACE}}}content", {"type": "html"}).text = content_html

    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = tempfile.NamedTemporaryFile(dir=output.parent, delete=False)
    try:
        with temporary:
            ET.ElementTree(feed).write(temporary, encoding="utf-8", xml_declaration=True)
        os.chmod(temporary.name, 0o644)
        os.replace(temporary.name, output)
    finally:
        Path(temporary.name).unlink(missing_ok=True)


def run_job(client, labels, summarize, database, output, *, now=None, deadline=None, clock=time.time, sample=random.sample):
    now = time.time() if now is None else now
    database = Path(database)
    output = Path(output)
    initialize_database(database)

    with sqlite3.connect(database) as connection:
        processed = {row[0] for row in connection.execute("SELECT id FROM processed_items")}

    label_of = {}
    window_totals = {}
    for label in labels:
        identifiers = client.fetch_label_ids(label, now=now)
        window_totals[label] = len(identifiers)
        for identifier in identifiers:
            label_of.setdefault(identifier, label)

    candidates = [identifier for identifier in label_of if identifier not in processed]
    if not candidates:
        return False
    selected = sample(candidates, min(MAX_ITEMS, len(candidates)))

    summaries = {label: [] for label in labels}
    done = []
    for item in client.fetch_contents(selected):
        article = normalize_item(item)
        if article is None:
            # digest 自身の entry は要約せず、再抽出されないよう処理済みにする
            if item.get("id"):
                done.append(item["id"])
            continue
        if deadline is not None and clock() >= deadline:
            print(f"time budget exhausted after {len(done)} items")
            break
        summaries[label_of.get(article["id"], labels[0])].append((article, summarize(article)))
        done.append(article["id"])

    sections = [(label, window_totals[label], summaries[label]) for label in labels]
    published = any(section_summaries for _label, _total, section_summaries in sections)
    local_date = datetime.datetime.fromtimestamp(now, ZoneInfo("Asia/Tokyo")).date().isoformat()
    updated_at = datetime.datetime.fromtimestamp(now, datetime.UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z")

    with sqlite3.connect(database) as connection:
        if published:
            connection.execute(
                "INSERT OR REPLACE INTO digests (id, updated_at, title, content_html) VALUES (?, ?, ?, ?)",
                (
                    f"urn:shishi:freshrss-digest:{local_date}",
                    updated_at,
                    f"{DIGEST_TITLE_PREFIX}{local_date}",
                    digest_content(sections),
                ),
            )
            connection.execute(
                "DELETE FROM digests WHERE id NOT IN (SELECT id FROM digests ORDER BY updated_at DESC LIMIT 7)"
            )
            write_feed(connection, output)
        connection.executemany(
            "INSERT OR IGNORE INTO processed_items (id, processed_at) VALUES (?, ?)",
            [(identifier, updated_at) for identifier in done],
        )
    return published


def read_credential(name):
    directory = Path(os.environ["CREDENTIALS_DIRECTORY"])
    return (directory / name).read_text().rstrip("\n")


def main():
    state_directory = Path(os.environ.get("STATE_DIRECTORY", "/var/lib/freshrss-digest"))
    labels = os.environ["DIGEST_LABELS"].split(",")
    now = time.time()
    freshrss = FreshRSSClient(
        read_credential("freshrss-api-url"),
        read_credential("freshrss-api-username"),
        read_credential("freshrss-api-password"),
    )
    ollama = OllamaClient(
        os.environ.get("OLLAMA_URL", "http://127.0.0.1:11434"),
        os.environ["OLLAMA_MODEL"],
    )
    created = run_job(
        freshrss,
        labels,
        ollama.summarize,
        state_directory / "state.sqlite3",
        state_directory / "public" / "digest.atom",
        now=now,
        deadline=time.time() + TIME_BUDGET_SECONDS,
    )
    print("published" if created else "no new items")


if __name__ == "__main__":
    main()
