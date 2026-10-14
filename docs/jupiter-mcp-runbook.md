# jupiter の Slate MCP トンネル

Slate の接続手順3以降を NixOS で管理します。手順1・2で用意した Slate、Tailscale Serve、
OpenAI のトンネル、実行用 API キーを使います。
同じ Slate へ、別の ID とキーを持つ追加トンネルを接続できます。
このトンネル定義はトンネル作成や Slate 本体の配備を行いません。
Slate 本体の起動・更新・公開は[Slate サービスの運用](slate-runbook.md)で管理します。

## 人間の出番

1. `nix run .#jupiter-secrets` に既存のトンネル ID、Main の HTTPS URL、実行用 API キーを入力します。キーは非表示です。
2. 追加トンネルを使う場合は、続く追加用の入力で別のトンネル ID と実行用 API キーを登録します。接続先は既存の Slate と共通です。
3. ChatGPT の本人認証が必要な場合はログインします。登録と操作確認は利用可能な接続ツールから行い、本人操作が必要な部分だけを切り分けます。

Nix のビルド・構成の差分確認・適用・サービス検査はエージェントが実行します。
CLI だけで個人用 plugin の登録や Plus の利用条件まで設定できるものではありません。

## 値を保存する

nix-config のルートで実行します。事前に秘密ファイルを作る必要はありません。

```sh
nix run .#jupiter-secrets
```

最初の LUKS・ログイン・SMB・Tailscale の各入力は、変更しなければ空 Enter で維持します。
続いて接続情報を入力します。

| 入力 | 値 |
| --- | --- |
| tunnel_id | Platform で作成した Slate 用トンネル ID。`tunnel_` に小文字英数字 32 文字が続く形式 |
| Main の HTTPS Origin | `https://slate.<tailnet の DNS suffix>.ts.net`。`/mcp` は自動で付加します |
| API キー・確認入力 | Restricted の Tunnels Read＋Use を持つ実行用キー。管理用キーは使いません |

既存の [Jupiter の秘密情報手順](jupiter-secrets-runbook.md) と同じ管理用 age 鍵を使います。
保存先は `secrets/jupiter/runtime.yaml` です。既存分は `openai-mcp-api-key` と `openai-mcp-slate-config`、
追加分は `openai-mcp-secondary-api-key` と `openai-mcp-secondary-config` を使います。
入力した値だけを更新し、空 Enter にした既存の秘密は維持します。
平文は tmpfs 内で扱い、既存の復号検証・更新失敗時の復元・一時ファイル削除を使います。
キー交換も同じコマンドです。既存分のトンネル ID を空 Enter にすると接続情報一式を維持し、未登録なら登録をスキップします。
既存分の ID を入力した場合は URL とキーを入力します。途中で入力を中断した場合やキーの確認が一致しない場合は、ほかの秘密も含めて保存しません。

追加分では別のトンネル ID と、確認付きの API キーを入力します。Main の HTTPS Origin は再入力しません。
既存分を同時に変更した場合は更新後の接続先を使い、登録済みの追加分も同じ接続先へ更新します。
既存の Slate 接続設定がない場合は、先に既存分を登録します。
追加分の ID を空 Enter にすると、登録済みの ID とキーを維持し、未登録ならスキップします。
追加分の入力に失敗した場合も、ほかの秘密を含めて保存しません。
既存分と追加分のトンネル ID が同じになる更新は拒否します。

既存分が未登録の間は Nix 評価が警告を出し、既存分のサービスを作りません。追加分は登録した場合だけ有効になります。
保存後の再評価で sops-nix とサービスが有効になります。
暗号化済みの変更は通常の秘密情報更新と同様に Git で管理します。

## Nix が管理するもの

- `pkgs/tunnel-client/`: 公式 Linux amd64 バイナリーをバージョンと SHA-256 で固定します。ホスト上の手動ダウンロードやソースコンパイルは不要です。
- `hosts/jupiter/mcp.nix`: sops-nix が復号した設定とキーを systemd credentials で渡します。キーを Nix store やコマンド引数の値に埋め込みません。
- `openai-mcp-tunnel-slate.service` と `openai-mcp-tunnel-secondary.service`: 各トンネルの起動前の `doctor`、常駐実行、異常終了時の再起動を管理します。システムサービスなのでユーザーのログインや Linger 設定は不要です。
- 管理 UI とヘルス確認は、既存分が `127.0.0.1:18080`、追加分が `127.0.0.1:18081` です。ファイアウォールへ公開ポートを追加しません。
- API キーと systemd credentials はサービスごとに分離します。追加分だけのキー更新では既存サービスを再起動しません。

2 つのトンネルは同じ Slate に接続します。追加用のトンネル ID と実行用 API キーは、Platform で別途用意します。
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
UI はホスト上の `http://127.0.0.1:18080/ui` です。起動状態だけでなく接続状態を確認します。
追加分を登録した場合は、次も確認します。

```sh
systemctl status openai-mcp-tunnel-secondary.service
journalctl -u openai-mcp-tunnel-secondary.service -n 50 --no-pager
curl --fail http://127.0.0.1:18081/readyz
```

追加分の UI は `http://127.0.0.1:18081/ui` です。

## ChatGPT への登録

以下は公式資料にあるカスタム MCP 接続の新規登録手順です。
対象アカウントで登録機能が利用可能であることが前提で、Nix はこの機能を有効化しません。
既存 plugin の設定に Tunnel の選択欄があるという意味ではありません。

サービスの稼働中に、利用するアカウントで ChatGPT Web の Plugins → ＋ →
Add custom MCP server を開きます。名前は Slate、Connection は Tunnel、
Authentication は No authentication とし、対象トンネルを選択します。
説明を確認して Create as a plugin を選び、個人用 plugin をインストールします。
追加分も同じ手順で、そのトンネルを使うアカウント・ワークスペースから追加用の ID を選びます。

`mcp.json` で `.ts.net/mcp` を指定した plugin は tailnet への直接接続です。
同名の Tunnel やこのサービスを用意しても接続方式は変わりません。
登録機能がない場合、上の手順では接続を作成できません。
Tunnel 一覧に対象だけがない場合は、ワークスペースへの関連付けと Read／Use 権限を確認します。

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
sops-nix が更新を検知して該当するサービスを再起動します。実際の読み取りに成功してから旧キーを失効させます。
一時停止・再開は次のコマンドです。

```sh
sudo systemctl stop openai-mcp-tunnel-slate.service
sudo systemctl start openai-mcp-tunnel-slate.service
```

追加分の停止・再開は、上のコマンドのサービス名を `openai-mcp-tunnel-secondary.service` に置き換えます。
一方のトンネルを停止しても、もう一方のサービスは停止しません。

トンネル停止は、この Tunnel を経由する操作を止めます。tailnet への直接接続は停止しません。Slate 自体と Tailscale Serve はこのサービスでは停止しません。
