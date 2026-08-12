# 統合ホストにおける home-manager activation の順序制約。
#
# HM の activation にはネットワークを使う処理がある(home/skk の辞書取得)。
# 既定では home-manager-<user>.service が network-online.target より先に走るため、
# 初回起動では必ず失敗する。VM リハーサルでの実測(2026-08-12):
#   activation 開始 12:29:21 / 辞書ダウンロード失敗 12:29:23 / network-online 到達 12:29:28
# standalone(earth)は人間が switch を叩くので既にネットワークがあり発生しない。
# 起動時に自動で activation が走る統合ホスト固有の問題なので、ここで順序を与える。
#
# home-manager を取り込まないホスト(DNS サーバー等)でも壊れないよう、
# 定義済みの HM ユーザーからサービス名を導出する。ユニット名は systemd の
# エスケープ規則に従う(ハイフンを含むユーザー名で HM 側と食い違わないように)。
{
  config,
  lib,
  utils,
  ...
}:
{
  systemd.services = lib.optionalAttrs (config ? home-manager) (
    lib.mapAttrs' (
      user: _:
      lib.nameValuePair "home-manager-${utils.escapeSystemdPath user}" {
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
      }
    ) config.home-manager.users
  );
}
