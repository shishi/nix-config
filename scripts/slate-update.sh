#!/usr/bin/env bash
set -euo pipefail
# slate-build.service の Conflicts/Before が両ランタイムの停止完了を待つ。
systemctl start slate-build.service
# ビルド失敗時は set -e で終了し、サーバーを起動しない。
systemctl start slate.service slate-run.service
