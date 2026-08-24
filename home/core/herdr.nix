{ pkgs, lib, ... }:
let
  herdrBootstrap = pkgs.writeShellApplication {
    name = "herdr-bootstrap";
    runtimeInputs = with pkgs; [
      llm-agents.herdr
      llm-agents.claude-code
      python3
      git # install-plugins.sh 内の claude plugin marketplace add が clone に使う
      jq # install-plugins.sh が使う
      gnugrep
      coreutils
      util-linux # flock
    ];
    text = ''
      export HERDR_NORMALIZE_HOOKS=${../../scripts/herdr-normalize-hooks.py}
      ${builtins.readFile ../../scripts/herdr-bootstrap.sh}
    '';
  };
in
{
  home.packages = [ herdrBootstrap ]; # 手動実行用に PATH にも置く

  # herdr 更新(integration script の版上がり)や新規マシンで integration と
  # skill の入れ直しが要るため、activation で冪等に確認する。非致命
  home.activation.herdrBootstrap = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    ${herdrBootstrap}/bin/herdr-bootstrap || true
  '';
}
