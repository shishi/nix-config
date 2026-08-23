{ ... }:
{
  nix.settings = {
    experimental-features = [
      "nix-command"
      "flakes"
    ];
    trusted-users = [ "shishi" ];
    # flake.nix の nixConfig(extra-substituters 等)を自動承認する設定。
    # trusted-users に対して全ての flake の nixConfig を無条件に信頼するため、
    # 外部 flake 経由でキャッシュ・署名鍵を差し替えられるサプライチェーンリスクがある。
    # 必要な substituters/trusted-public-keys は shared/nix-caches.nix で直接設定済みなので
    # 通常は不要(警告が出るだけで実害はない)。有効化したい場合のみ次行のコメントを外すか、
    # `nh os switch --accept-flake-config` のように都度フラグで渡す。
    # accept-flake-config = true;
  }
  // (import ../shared/nix-caches.nix).forNixSettings;
}
