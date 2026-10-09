# jupiter の Slate MCP トンネル

Slate の接続手順3以降を NixOS で管理します。手順1・2で用意した Slate、Tailscale Serve、
OpenAI のトンネル、実行用 API キーを使います。トンネル作成や Slate 本体の配備は行いません。

## 人間の出番

1. `nix run .#jupiter-secrets -- --mcp` に既存のトンネル ID、Main の HTTPS URL、実行用 API キーを入力します。キーは非表示です。
2. 適用後に ChatGPT Web の個人用 plugin を登録します。本人のログインが必要です。
3. Web とモバイルの両方で読み書きを確認します。

Nix のビルド・構成の差分確認・適用・サービス検査はエージェントが実行します。
CLI だけで個人用 plugin の登録や Plus の利用条件まで設定できるものではありません。

## 値を保存する

nix-config のルートで実行します。事前に秘密ファイルを作る必要はありません。

```sh
nix run .#jupiter-secrets -- --mcp
```

入力は次の順です。

| 入力 | 値 |
| --- | --- |
| tunnel_id | Platform で作成した Slate 用トンネル ID |
| Main の HTTPS Origin | `https://slate.<tailnet の DNS suffix>.ts.net`。`/mcp` は自動で付加します |
| API キー・確認入力 | Restricted の Tunnels Read＋Use を持つ実行用キー。管理用キーは使いません |

既存の [Jupiter の秘密情報手順](jupiter-secrets-runbook.md) と同じ管理用 age 鍵を使います。
保存先は `secrets/jupiter/runtime.yaml` の `openai-mcp-api-key` と `openai-mcp-slate-config` です。
`--mcp` では接続情報だけを更新し、SMB・Tailscale・bootstrap の値を維持します。
平文は tmpfs 内で扱い、既存の復号検証・更新失敗時の復元・一時ファイル削除を使います。
キー交換も同じコマンドです。空入力や確認不一致では保存しません。

両項目が未登録の間は Nix 評価が警告を出し、サービスを作りません。
保存後の再評価で sops-nix とサービスが有効になります。
暗号化済みの変更は通常の秘密情報更新と同様に Git で管理します。

## Nix が管理するもの

- `pkgs/tunnel-client/`: 公式 Linux amd64 バイナリーをバージョンと SHA-256 で固定します。ホスト上の手動ダウンロードやソースコンパイルは不要です。
- `hosts/jupiter/mcp.nix`: sops-nix が復号した設定とキーを systemd credentials で渡します。キーを Nix store やコマンド引数の値に埋め込みません。
- `openai-mcp-tunnel-slate.service`: 起動前の `doctor`、常駐実行、異常終了時の再起動を管理します。システムサービスなのでユーザーのログインや Linger 設定は不要です。
- 管理 UI とヘルス確認は `127.0.0.1:18080` に限定します。ファイアウォールへ公開ポートを追加しません。

同じホストで別の MCP を使う場合は、別の接続設定・トンネル・サービスと別の localhost 管理ポートを割り当てます。
OpenAI の Organization や Tailscale ホストを Slate 専用にする必要はありません。

## 適用と確認

```sh
nix build .#nixosConfigurations.jupiter.config.system.build.toplevel --dry-run
nix build .#nixosConfigurations.jupiter.config.system.build.toplevel
sudo ./result/bin/switch-to-configuration switch
systemctl status openai-mcp-tunnel-slate.service
journalctl -u openai-mcp-tunnel-slate.service -n 50 --no-pager
curl --fail http://127.0.0.1:18080/readyz
```

適用前に、別作業の Nix 変更が同じ構成に含まれていないかを確認します。
`doctor` が失敗する場合は、ログでトンネル権限・接続先への到達性・TLS を確認します。
UI は jupiter 上の `http://127.0.0.1:18080/ui` です。起動状態だけでなく接続状態を確認します。

## ChatGPT への登録

サービスの稼働中に、利用するアカウントで ChatGPT Web の Plugins → ＋ →
Add custom MCP server を開きます。名前は Slate、Connection は Tunnel、
Authentication は No authentication とし、対象トンネルを選択します。
説明を確認して Create as a plugin を選び、個人用 plugin をインストールします。

新規 Chat または Work で Slate を選び、確認用ノートの作成・読み取り・版付き更新・再読を行います。
モバイルでも同じアカウントとワークスペースで別の新規会話を作り、同じ操作を確認します。
Slate 本体の本文とアクティビティまで照合し、試験ノートはプレビュー確認後にごみ箱へ移します。

公開資料は Plus の個人用 Tunnel 接続のモバイル書き込みを一貫して保証していません。
また、トンネル固有の料金・支払い登録条件も明記されていません。
この Nix 設定の成功をそれらの保証とは扱いません。
[公式登録手順](https://developers.openai.com/api/docs/guides/custom-mcp-server)と
[トンネル仕様](https://developers.openai.com/api/docs/guides/secure-mcp-tunnels)を参照してください。

## 更新と停止

キー交換は入力コマンドを再実行してから NixOS を再適用します。
sops-nix が更新を検知してサービスを再起動します。実際の読み取りに成功してから旧キーを失効させます。
一時停止・再開は次のコマンドです。

```sh
sudo systemctl stop openai-mcp-tunnel-slate.service
sudo systemctl start openai-mcp-tunnel-slate.service
```

トンネル停止は ChatGPT の操作を止めます。Slate 自体と Tailscale Serve はこのサービスでは停止しません。
