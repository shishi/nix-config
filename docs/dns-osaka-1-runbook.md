# dns-osaka-1 導入・運用手順

## 導入前

対象は OCI の `VM.Standard.A1.Flex`（2 OCPU、メモリ 12 GB、Boot Volume 200 GB、
Public IP `129.225.177.221`）である。`nixos-anywhere` は `/dev/sda` を全消去する。

1. OCI Console で Boot Volume Backup を作成し、`AVAILABLE` になるまで待つ。
2. 現在の Ubuntu の SSH host key を作業端末の `known_hosts` に登録する(登録済みなら何もしない)。
   instance 作成時に登録した自分の公開鍵がサーバーの `authorized_keys` にあることを
   機械照合してから記録する。照合が通らなければ何も記録せず失敗する。
   以降の全接続(インストール本体を含む)は wrapper がこの記録と照合し、不一致なら拒否する。

```console
ssh-keygen -F 129.225.177.221 >/dev/null || { ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no ubuntu@129.225.177.221 'cat ~/.ssh/authorized_keys' | ssh-keygen -lf /dev/stdin | grep -qF "$(ssh-keygen -lf ~/.ssh/id_ed25519.pub | awk '{print $2}')" && ssh-keyscan -t ed25519 129.225.177.221 >> ~/.ssh/known_hosts; }
```

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

OCI Console では Oracle Cloud Agent の `Compute Instance Monitoring` を有効にし、
`oci_computeagent` namespace の `MemoryUtilization` が1分単位で届くことを確認する。
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

## バックアップ削除条件

Public SSH、二台のDNS応答、AdGuard管理画面、Ollama常駐、FreshRSS digest、OCIの
`MemoryUtilization` 到着を確認した後にだけ、導入前のBoot Volume Backupを削除する。

Tailscaleが停止した場合もPublic SSHは利用できる。モバイルの広告除去DNSは利用できなくなり、
端末はTailscaleを切れば端末側の通常DNS（設定していればNextDNS）へ戻る。
