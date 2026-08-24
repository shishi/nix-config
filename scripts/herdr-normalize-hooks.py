#!/usr/bin/env python3
"""herdr integration が書く絶対パスの hook 登録を ~ 形式へ正規化する。

`herdr integration install` は設定ファイルに自マシンの絶対パスで hook を
追記する。~/.claude/settings.json と ~/.codex/hooks.json は dotfiles で
マシン間共有しているため、絶対パスのままだと他マシンで「ファイルが無い」
エラーになる。ここで ~ 形式 1 エントリへ畳む。

usage: herdr-normalize-hooks.py <settings-json> <canonical-command> [--no-matcher]
  herdr-agent-state.sh を含む SessionStart hook を全て除去し、
  1 つでも存在した場合のみ canonical-command のエントリを 1 つ追加する。
"""

import contextlib
import json
import os
import sys
import tempfile

MARKER = "herdr-agent-state.sh"


def write_atomic(real_path: str, content: str) -> None:
    """同一ディレクトリの一時ファイル経由で置換し、中断時に壊れた設定を残さない。"""
    directory = os.path.dirname(real_path)
    fd, tmp_path = tempfile.mkstemp(dir=directory, prefix=".herdr-normalize-")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(content)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp_path, real_path)
    except BaseException:
        with contextlib.suppress(FileNotFoundError):
            os.unlink(tmp_path)
        raise


def normalize(path: str, canonical: str, with_matcher: bool) -> bool:
    # symlink(dotfiles 配備)を実体へ解決する。symlink の path へ os.replace
    # すると link 自体が実ファイルへ置き換わり dotfiles 管理から外れる
    real_path = os.path.realpath(path)
    try:
        with open(real_path, encoding="utf-8") as f:
            original = f.read()
    except FileNotFoundError:
        return False

    data = json.loads(original)
    before = json.loads(original)  # 書き換え判定は構造比較で行う(下記)
    session_start = data.get("hooks", {}).get("SessionStart")
    if not isinstance(session_start, list):
        return False

    had_herdr = False
    kept_blocks = []
    for block in session_start:
        hooks = block.get("hooks", [])
        kept = [h for h in hooks if MARKER not in h.get("command", "")]
        if len(kept) != len(hooks):
            had_herdr = True
        if kept:
            block = dict(block, hooks=kept)
            kept_blocks.append(block)
        elif hooks == []:
            kept_blocks.append(block)

    if had_herdr:
        entry = {"type": "command", "command": canonical, "timeout": 10}
        block = {"matcher": "*", "hooks": [entry]} if with_matcher else {"hooks": [entry]}
        kept_blocks.append(block)

    data["hooks"]["SessionStart"] = kept_blocks
    # 手で整形されたファイルの書式は json.dumps と一致しないことがある。
    # 文字列比較だと整形差だけで毎回全体を書き換えてしまうため、
    # hook 構造が実際に変わったときだけ書く(その際は全体が再整形される)
    if data == before:
        return False
    result = json.dumps(data, indent=2, ensure_ascii=False) + "\n"
    write_atomic(real_path, result)
    return True


def main() -> int:
    args = [a for a in sys.argv[1:] if a != "--no-matcher"]
    if len(args) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    with_matcher = "--no-matcher" not in sys.argv[1:]
    # 「無い」と「変更不要」をログで区別する(unchanged は実在の含意を持つ)
    if not os.path.exists(os.path.realpath(args[0])):
        print(f"missing: {args[0]}")
        return 0
    # 並行実行の直列化は呼び出し元(herdr-bootstrap の flock)が担う
    changed = normalize(args[0], args[1], with_matcher)
    print(f"{'normalized' if changed else 'unchanged'}: {args[0]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
