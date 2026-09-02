# dns-osaka-1 導入・運用手順

## OCI Console での手作業(全一覧)

コードや SSH で代替できない Oracle 画面の操作はこれだけで、これ以外に無い。
それぞれの詳細は参照先の節にある。

| いつ | 操作 | 詳細 |
|---|---|---|
| インストール前 | Boot Volume Backup を手動で 1 個作成 | [導入前](#導入前) 手順 1 |
| 一度だけ(未実施なら) | IPv6 の開通(VCN → サブネット → ルート → セキュリティリスト → VNIC) | [IPv6](#ipv6) |
| 初回起動後 | Metrics Explorer で `MemoryUtilization` の到着確認(届かないときだけ Agent 設定を確認) | [NixOS 起動後](#nixos-起動後) |
| 全チェック green 後 | 導入前バックアップの削除 | [バックアップ削除条件](#バックアップ削除条件) |

## 導入前

対象は OCI の `VM.Standard.A1.Flex`（2 OCPU、メモリ 12 GB、Boot Volume 200 GB、
Public IP `129.225.177.221`）である。`nixos-anywhere` は `/dev/sda` を全消去する。

1. OCI Console で Boot Volume Backup を作成し、`Available` になるまで待つ。
   - **Storage → Block Storage → Boot Volumes** の一覧から `dns-osaka-1 (Boot Volume)` を開く
     (インスタンス詳細の Storage タブにあるボリューム名リンクは反応しないことがあるため、
     一覧ページ経由で入る)
   - 上部タブ **Backups** → **Create boot volume backup**
   - Name: `dns-osaka-1-boot-manual-<日付>`、Backup type: **Full backup**(既定)、
     Data retention: **No retention period (keep until deleted)**(既定)、Tags: なし
   - 実行後、State が `Request received` → `Available` になるのを待つ
   - Always Free のボリュームバックアップ枠は 5 個。Bronze/Silver/Gold の
     バックアップポリシーは世代数が 5 個を超えるため割り当てない。
     手動 1 個だけ作り、[バックアップ削除条件](#バックアップ削除条件)を満たしたら削除する
2. SSH host key の登録は `dns-osaka-1-install` が自動で行う(登録済みなら何もしない)。
   instance 作成時に登録した自分の公開鍵がサーバーの `authorized_keys` にあることを
   機械照合してから記録し、照合が通らなければ何も記録せず停止する。
   以降の全接続(インストール本体を含む)はこの記録と照合され、不一致なら拒否される。
3. `tailscale-config` の `tag:dns` 追加を適用し、Tailscale で `auth_keys` scope と
   `tag:dns` を持つ、このホスト専用 OAuth client を作る。
4. FreshRSS の Google Reader API を有効にし、API password を発行する。
5. `secrets/management-age-key.txt`(または `SOPS_AGE_KEY_FILE` の指す先)に
   管理用 age 鍵を用意する。この鍵は Git 追跡外で、jupiter の秘密情報と共通である
   ([usage.md の秘密情報の節](usage.md#秘密情報)を参照)。
6. 次を実行し、暗号化された `runtime.yaml` の4項目を実値へ置換する。

```console
nix run .#dns-osaka-1-secrets
```

- `tailscale-oauth-secret`: `tskey-client-` で始まる OAuth client secret
- `freshrss-api-url`: FreshRSS のルートURL（末尾の `/api/greader.php` は含めない）
- `freshrss-api-username`: FreshRSS username
- `freshrss-api-password`: FreshRSS API password

暗号文3ファイルをコミットしてからインストールする。

```console
git add secrets/dns-osaka-1/.sops.yaml secrets/dns-osaka-1/bootstrap.yaml secrets/dns-osaka-1/runtime.yaml
git commit
```

## NixOS インストール

バックアップが `AVAILABLE` であることを再確認してから実行する。

```console
nix run .#dns-osaka-1-install
```

ラッパーは `StrictHostKeyChecking=yes` を強制する。固定しているkexecイメージはUbuntuの
SSH host keyをNixOSインストーラへ引き継ぎ、さらに完成後のNixOSへ同じkeyをコピーするため、
全工程を登録済みのkeyで検証する。管理用 age 鍵でホスト専用 age 鍵を tmpfs に復号し、
インストール先の
`/var/lib/sops-nix/dns-osaka-1-age-key.txt` へ配送する。FreshRSS と Tailscale の秘密値は
ホスト上で sops-nix が `/run/secrets` へ復号する。

## NixOS 起動後

Public SSH は Tailscale と独立している。

```console
ssh shishi@129.225.177.221
```

次を確認する。

```console
sudo systemctl --failed
```

```console
sudo systemctl status adguardhome ollama ollama-model-loader ollama-warm nginx oracle-cloud-agent tailscaled
```

```console
tailscale ip -4
```

Oracle の Tailscale IP が確定したら `tailscale-config` の `dns.json` を更新し、Oracle と
Synology (`100.71.227.37`) を Global nameserver にして Override local DNS を有効化する。
DNS、AdGuard管理画面、Ollama API、Atom feed の公開先は `tailscale0` だけである。

```console
dig @<oracle-tailscale-ip> example.com
```

```console
curl http://<oracle-tailscale-ip>:11434/api/tags
```

OCI Console の Observability → Metrics Explorer で、`oci_computeagent` namespace の
`MemoryUtilization` が届くことを確認する(エージェントは構成が自前で動かしており、
届かないときだけインスタンスの Oracle Cloud Agent タブで
`Compute Instance Monitoring` が Enabled かを確認する)。
12 GBの20%は2.4 GBである。`qwen3:4b-instruct-2507-q4_K_M` は2.5 GBのモデルで、
`ollama-warm` が常駐させるが、判定に使われる実測値が20%を超えることはグラフで確認する。

## FreshRSS digest

タイマーは毎日06:00 JSTに最大100件、過去7日以内の未処理記事を取得する。記事ごとに
Ollamaで要約し、すべて成功したときだけSQLiteへ処理済みIDを記録してAtomを更新する。
HTTP/API失敗は最大3回まで試し、失敗したバッチは公開・処理済み化しない。

最初の成功後、FreshRSS に次のfeedを登録する。

```text
http://<oracle-tailscale-ip>:8080/digest.atom
```

生成entryのtitle prefixを入力時に除外するため、digest feed自身は再要約されない。

## Synology の二台目 AdGuard Home

Container Manager のProjectとして
`deploy/synology-adguardhome/compose.yaml` を使う。イメージはOracle側と同じ
AdGuard Home `v0.107.78` に固定している。DSM 7版Tailscaleのハイブリッド方式は
`100.71.227.37` 宛のTCP/UDPをloopbackへ転送するため、Container側は
`127.0.0.1` にだけbindし、LANには公開しない。

1. `/volume1/docker/adguardhome/work` と `/volume1/docker/adguardhome/conf` を作る。
2. Oracle側のAdGuard Homeを停止する。
3. `/var/lib/AdGuardHome/AdGuardHome.yaml` を
   `/volume1/docker/adguardhome/conf/AdGuardHome.yaml` へ一度だけコピーする。
4. Oracle側を再開する。
5. Container ManagerでProjectを起動する。

設定の継続同期は行わない。両ホストのquery logも別々に保持し、設定済みの保持期間は
最大30日である。

## IPv6

OS 側は `networking.useDHCP` の dhcpcd が DHCPv6 で自動取得するため、必要なのは
Oracle 側の設定だけである。順序は依存関係で決まっており、上位が空だと次の画面の
選択肢が出ない。

1. **対象 VCN(仮想クラウドネットワーク)の特定**: 同名の VCN があるため名前で選ばない。
   インスタンスの Internal FQDN に含まれる VCN 名と、VCN Details の
   **DNS Domain Name** を照合する。
2. **VCN に /56 を追加**: VCN 詳細 → IP administration → Add CIDR Block/Prefix →
   「Assign an Oracle allocated IPv6 /56 prefix」を ON(BYOIP・ULA は使わない)。
   既存の IPv4 通信は切れない。
3. **サブネットに /64 を切る**: サブネット → IP administration → Add IPv6 Prefix →
   下位 8 ビットを 16 進 2 桁で指定(サブネットが 1 個なら `00`)。
4. **ルート表に IPv6 デフォルトルート**: Add Route Rule → Destination `::/0` →
   Target は v4 の `0.0.0.0/0` と同じ Internet Gateway(IPv6 に NAT は無い)。
5. **セキュリティリスト**: Egress に `::/0`・All Protocols を追加(ステートフルなので
   外向き用途に ingress は不要)。Ingress は次の 2 つだけ:
   `::/0` IPv6-ICMP All(経路 MTU 探索・近隣探索に実質必須)、
   `::/0` と `0.0.0.0/0` の UDP 41641(Tailscale の WireGuard 直結。
   無くても中継サーバー経由で動くが遅くなる)。
   **53/853 の ingress は開けない** — Tailscale の DNS はトンネル内を通って
   `tailscale0` に出るため VNIC のポートには届かず、開けても
   オープンリゾルバを公開するだけになる。
6. **VNIC(インスタンスの仮想 NIC)にアドレス割当**: インスタンス → Attached VNICs →
   primary → IP administration → IPv6 Addresses → Assign(subnet prefix から自動割当)。
7. **OS 側の操作は不要**。確認は `ip -6 addr show scope global` と
   `ping -6 -c2 2606:4700:4700::1111`。

割り当てられるアドレスは Ephemeral で、VNIC を作り直すと変わる。
DNS レコードへ直接書く場合は Reserved 化するか、変更前提の運用にする。

## バックアップ削除条件

Public SSH、二台のDNS応答、AdGuard管理画面、Ollama常駐、FreshRSS digest、OCIの
`MemoryUtilization` 到着を確認した後にだけ、導入前のBoot Volume Backupを削除する。

Tailscaleが停止した場合もPublic SSHは利用できる。モバイルの広告除去DNSは利用できなくなり、
端末はTailscaleを切れば端末側の通常DNS（設定していればNextDNS）へ戻る。
