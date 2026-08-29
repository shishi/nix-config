{ inputs, self, ... }:
{
  perSystem =
    { pkgs, ... }:
    let
      # eval のみ強制する check(drvPath を text に埋めると評価が走る)
      evalOnly =
        name: cfg:
        # unsafeDiscardStringContext が無いと drvPath の文字列コンテキストが
        # 全依存を持ち込み、`nix flake check` がフル realization してしまう(実測)
        pkgs.writeText "${name}-eval" (
          builtins.unsafeDiscardStringContext cfg.config.system.build.toplevel.drvPath
        );
      caches = import ../shared/nix-caches.nix;
      skkRules = import ../home/skk/rules.nix { inherit (pkgs) lib; };
      # libskk はルールを ~/.config/libskk/rules から読む。
      # home/skk/rules.nix と同じ定義でルールディレクトリを組み立てる。
      skkRuleDir = pkgs.runCommand "skk-test-rules" { } ''
        mkdir -p $out/StickyShift/rom-kana $out/StickyShift/keymap
        cp ${pkgs.writeText "metadata.json" (builtins.toJSON skkRules.metadata)} \
          $out/StickyShift/metadata.json
        cp ${pkgs.writeText "hiragana.json" (builtins.toJSON skkRules.keymapHiragana)} \
          $out/StickyShift/keymap/hiragana.json
        cp ${pkgs.writeText "katakana.json" (builtins.toJSON skkRules.keymapKatakana)} \
          $out/StickyShift/keymap/katakana.json
        cp ${
          pkgs.writeText "rom-kana.json" (
            builtins.toJSON {
              include = [ "default/default" ];
              define.rom-kana = skkRules.romKana;
            }
          )
        } $out/StickyShift/rom-kana/default.json
      '';
    in
    {
      checks = {
        direnv-contract = pkgs.runCommand "direnv-contract" { } ''
          ${pkgs.bash}/bin/bash ${../scripts/direnv.test.sh} ${../.envrc}
          ${pkgs.bash}/bin/bash ${../scripts/direnv.test.sh} ${../templates/ruby/.envrc}
          touch $out
        '';

        # 可搬グラフ信号(ビルド)
        home-shishi = self.homeConfigurations."shishi".activationPackage;
        nixos-wsl-toplevel = self.nixosConfigurations.nixos-wsl.config.system.build.toplevel;

        # 合成 DE(eval。update の main 編入時は実 build — scripts/update.sh 参照)
        synth-gnome-eval = evalOnly "synth-gnome" self.nixosConfigurations.synth-gnome;
        synth-kde-eval = evalOnly "synth-kde" self.nixosConfigurations.synth-kde;

        # jupiter はスタブ hardware のため隔離名(「実機 OK」と誤読させない)。
        # 実 hardware-configuration.nix の commit 後に jupiter-toplevel として既定編入する
        jupiter-stub-eval = evalOnly "jupiter-stub" self.nixosConfigurations.jupiter;

        # 秘密情報の作成・復号を一時 shell なしで実行できることを固定する。
        jupiter-sops-cli-contract =
          let
            hm = self.nixosConfigurations.jupiter.config.home-manager.users.shishi;
          in
          pkgs.runCommand "jupiter-sops-cli-contract" { } ''
            ${if builtins.elem pkgs.sops hm.home.packages then "true" else "false"} || {
              echo "Jupiter Home Manager packages do not include sops"
              exit 1
            }
            touch $out
          '';

        # ChatGPT Desktop は OpenAI の version 付き Linux package を使う。
        # /latest/ は同じ lock の取得物が上流更新で変わり、固定 hash と衝突するため禁止する。
        chatgpt-desktop-contract =
          let
            hm = self.nixosConfigurations.jupiter.config.home-manager.users.shishi;
            desktop = hm.programs.codexDesktopLinux;
            packages = builtins.filter (
              candidate: (candidate.meta.mainProgram or "") == "codex-desktop"
            ) hm.home.packages;
            package =
              if builtins.length packages == 1 then
                builtins.head packages
              else
                throw "Home Manager must install exactly one codex-desktop package";
            upstreamUrl = package.passthru.upstreamDeb.url;
            expectedUpstreamUrl = "https://persistent.oaistatic.com/codex-app-prod/linux/deb/pool/main/c/chatgpt/chatgpt_${package.version}_amd64.deb";
            expectedLinuxFeatures = [
              "automation-extensions"
              "directory-only-working-tree-watch"
              "node-repl-reaper"
              "project-group-last-updated-sort"
              "tray-usage"
            ];
            expectedPackageLinuxFeatures = [
              "automation-extensions"
              "computer-use-linux"
              "directory-only-working-tree-watch"
              "node-repl-reaper"
              "project-group-last-updated-sort"
              "tray-usage"
            ];
            toolkitAccessibility =
              hm.dconf.settings."org/gnome/desktop/interface"."toolkit-accessibility" or false;
            widgets = builtins.concatMap (panel: panel.widgets) hm.programs.plasma.panels;
            iconTasks = pkgs.lib.findFirst (widget: widget.name == "org.kde.plasma.icontasks") { } widgets;
            launchers = iconTasks.config.General.launchers or [ ];
          in
          pkgs.runCommand "chatgpt-desktop-contract" { } ''
            fail() {
              echo "$1"
              exit 1
            }

            [ "${if desktop.enable then "true" else "false"}" = true ] || \
              fail "codexDesktopLinux is disabled"
            ${if desktop.linuxFeatures == expectedLinuxFeatures then "true" else "false"} || \
              fail "codex-desktop Linux feature selection differs from the approved set"
            [ "${if desktop.computerUseUi.enable then "true" else "false"}" = true ] || \
              fail "codex-desktop Computer Use UI is disabled"
            ${if package.passthru.linuxFeatureIds == expectedPackageLinuxFeatures then "true" else "false"} || \
              fail "installed codex-desktop package does not contain the approved Linux features"
            [ "${if hm.dconf.enable then "true" else "false"}" = true ] || \
              fail "dconf is disabled for the Computer Use accessibility setting"
            [ "${if toolkitAccessibility then "true" else "false"}" = true ] || \
              fail "AT-SPI toolkit accessibility is not persisted"
            [ "${if desktop.remoteMobileControl.enable then "true" else "false"}" = false ] || \
              fail "codex-desktop remote mobile control is enabled"
            [ "${if desktop.remoteControl.enable then "true" else "false"}" = false ] || \
              fail "codex-desktop remote control service is enabled"
            [ "${hm.home.sessionVariables.CODEX_LINUX_DISABLE_USAGE_REPORTING or ""}" = 1 ] || \
              fail "community usage reporting is not disabled for login sessions"
            [ "${hm.systemd.user.sessionVariables.CODEX_LINUX_DISABLE_USAGE_REPORTING or ""}" = 1 ] || \
              fail "community usage reporting is not disabled for systemd user services"
            [ "${upstreamUrl}" = "${expectedUpstreamUrl}" ] || \
              fail "ChatGPT package does not use its exact versioned official CDN URL"
            CODEX_LINUX_DISABLE_USAGE_REPORTING=1 ${pkgs.lib.getExe package} --diagnose >/dev/null
            [ -f ${package}/share/applications/codex-desktop.desktop ] || \
              fail "codex-desktop desktop entry is missing"
            ${if builtins.elem "applications:codex-desktop.desktop" launchers then "true" else "false"} || \
              fail "KDE taskbar does not pin codex-desktop.desktop"
            ${if builtins.elem "applications:chatgpt.desktop" launchers then "false" else "true"} || \
              fail "KDE taskbar still pins chatgpt.desktop"
            touch $out
          '';

        # 実行時の SMB 資格情報は sops-nix が /run/secrets へ復号し、
        # NAS は boot を妨げない systemd automount として接続する。
        jupiter-smb-secrets-contract =
          let
            cfg = self.nixosConfigurations.jupiter.config;
            secret = cfg.sops.secrets."smb-mars-shishi";
            mount = cfg.fileSystems."/mnt/mars/shishi";
            gpgImport = cfg.systemd.services."import-shishi-gpg-secret" or { };
            gpgImportPath = pkgs.lib.makeBinPath (gpgImport.path or [ ]);
            requiredOptions = [
              "credentials=/run/secrets/smb-mars-shishi"
              "uid=1000"
              "gid=100"
              "file_mode=0600"
              "dir_mode=0700"
              "_netdev"
              "noauto"
              "x-systemd.automount"
              "x-systemd.idle-timeout=5min"
              "x-systemd.mount-timeout=10s"
            ];
          in
          pkgs.runCommand "jupiter-smb-secrets-contract" { } ''
            ok=1
            check() {
              if [ "$2" != "$3" ]; then
                echo "$1: expected '$3' but got '$2'"
                ok=0
              fi
            }
            check sops.age.keyFile "${cfg.sops.age.keyFile}" "/var/lib/sops-nix/key.txt"
            check sops.age.generateKey "${if cfg.sops.age.generateKey then "true" else "false"}" "false"
            check secret.owner "${secret.owner}" "root"
            check secret.group "${secret.group}" "root"
            check secret.mode "${secret.mode}" "0400"
            check mount.device "${mount.device}" "//mars/shishi"
            check mount.fsType "${mount.fsType}" "cifs"
            check gpgImport.wantedBy "${
              if builtins.elem "multi-user.target" (gpgImport.wantedBy or [ ]) then "present" else "missing"
            }" "present"
            check gpgImport.conditionPathExists "${gpgImport.unitConfig.ConditionPathExists or ""}" \
              "/home/shishi/gpg-secret.asc"
            check gpgImport.type "${gpgImport.serviceConfig.Type or ""}" "oneshot"
            check gpgImport.user "${gpgImport.serviceConfig.User or ""}" "shishi"
            check gpgImport.group "${gpgImport.serviceConfig.Group or ""}" "users"
            check gpgImport.umask "${gpgImport.serviceConfig.UMask or ""}" "0077"
            check gpgImport.gnupgPath "${
              if builtins.elem pkgs.gnupg (gpgImport.path or [ ]) then "present" else "missing"
            }" "present"
            check gpgImport.coreutilsPath "${
              if builtins.elem pkgs.coreutils (gpgImport.path or [ ]) then "present" else "missing"
            }" "present"
            check gpgImport.bashPath "${
              if builtins.elem pkgs.bash (gpgImport.path or [ ]) then "present" else "missing"
            }" "present"
            check gpgImport.gawkPath "${
              if builtins.elem pkgs.gawk (gpgImport.path or [ ]) then "present" else "missing"
            }" "present"
            check gpgImport.scriptReference "${
              if pkgs.lib.hasInfix "import-gpg-secret.sh" (gpgImport.script or "") then "present" else "missing"
            }" "present"
            check gpgImport.exportArgument "${
              if pkgs.lib.hasInfix "/home/shishi/gpg-secret.asc" (gpgImport.script or "") then
                "present"
              else
                "missing"
            }" "present"
            check gpgImport.homeArgument "${
              if pkgs.lib.hasInfix "/home/shishi/.gnupg" (gpgImport.script or "") then "present" else "missing"
            }" "present"
            ${pkgs.lib.concatMapStringsSep "\n" (option: ''
              check "mount.options.${option}" "${
                if builtins.elem option mount.options then "present" else "missing"
              }" "present"
            '') requiredOptions}
            if ! ${pkgs.coreutils}/bin/env -i PATH="${gpgImportPath}" bash -c 'command -v awk >/dev/null'; then
              echo "gpgImport.path cannot run the script's bash and awk dependencies"
              ok=0
            fi
            [ "$ok" = 1 ] || exit 1
            touch $out
          '';

        # Jupiter は SOPS で復号した OAuth client secret を使って tailnet へ自動参加し、
        # tag:jupiter の永続ノードとして Tailscale SSH を公開する。
        jupiter-tailscale-contract =
          let
            cfg = self.nixosConfigurations.jupiter.config;
            tailscale = cfg.services.tailscale;
            secret = cfg.sops.secrets."tailscale-oauth-secret" or { };
            autoconnect = cfg.systemd.services.tailscaled-autoconnect;
            tailscaledSet = cfg.systemd.services.tailscaled-set;
            showNullable = value: if value == null then "" else toString value;
          in
          pkgs.runCommand "jupiter-tailscale-contract" { } ''
            ok=1
            check() {
              if [ "$2" != "$3" ]; then
                echo "$1: expected '$3' but got '$2'"
                ok=0
              fi
            }
            check tailscale.enable "${if tailscale.enable then "true" else "false"}" "true"
            check tailscale.authKeyFile "${showNullable tailscale.authKeyFile}" \
              "/run/secrets/tailscale-oauth-secret"
            check tailscale.authKeyParameters.ephemeral "${
              if tailscale.authKeyParameters.ephemeral == false then "false" else "not-false"
            }" "false"
            check tailscale.authKeyParameters.preauthorized "${
              if tailscale.authKeyParameters.preauthorized == true then "true" else "not-true"
            }" "true"
            check tailscale.extraUpFlags '${builtins.toJSON tailscale.extraUpFlags}' \
              '["--advertise-tags=tag:jupiter"]'
            check tailscale.extraSetFlags '${builtins.toJSON tailscale.extraSetFlags}' '["--ssh"]'
            check secret.path "${secret.path or ""}" "/run/secrets/tailscale-oauth-secret"
            check secret.owner "${secret.owner or ""}" "root"
            check secret.group "${secret.group or ""}" "root"
            check secret.mode "${secret.mode or ""}" "0400"
            check tailscaled-autoconnect.after "${
              if builtins.elem "tailscaled.service" autoconnect.after then "present" else "missing"
            }" "present"
            check tailscaled-set.after "${
              if builtins.elem "tailscaled-autoconnect.service" tailscaledSet.after then "present" else "missing"
            }" "present"
            [ "$ok" = 1 ] || exit 1
            touch $out
          '';

        encrypted-secrets-contract = pkgs.runCommand "encrypted-secrets-contract" { } ''
          fail() {
            echo "$1"
            exit 1
          }

          sops_config=${../.sops.yaml}
          bootstrap_file=${../secrets/bootstrap.yaml}
          runtime_file=${../secrets/runtime.yaml}

          if ${pkgs.gnugrep}/bin/grep -q 'AGE-SECRET-KEY-' "$sops_config"; then
            fail ".sops.yaml contains an age private key"
          fi
          [ "$(${pkgs.yq-go}/bin/yq -r '.creation_rules | length' "$sops_config")" = 2 ] || \
            fail ".sops.yaml must contain exactly two creation rules"
          rule_paths=$(${pkgs.yq-go}/bin/yq -o=json -I=0 \
            '[.creation_rules[].path_regex] | sort' "$sops_config")
          [ "$rule_paths" = '["^secrets/bootstrap\\.yaml$","^secrets/runtime\\.yaml$"]' ] || \
            fail ".sops.yaml creation rules target unexpected paths"

          management_recipient=$(${pkgs.yq-go}/bin/yq -r \
            '.creation_rules[] | select(.path_regex | contains("bootstrap")) | .age' "$sops_config")
          runtime_recipient=$(${pkgs.yq-go}/bin/yq -r \
            '.creation_rules[] | select(.path_regex | contains("runtime")) | .age' "$sops_config")
          case "$management_recipient" in age1*) ;; *) fail "bootstrap creation rule has no public age recipient" ;; esac
          case "$runtime_recipient" in age1*) ;; *) fail "runtime creation rule has no public age recipient" ;; esac
          [ "$management_recipient" != "$runtime_recipient" ] || fail "bootstrap and runtime recipients must differ"

          check_secret_file() {
            label=$1
            file=$2
            expected_keys=$3
            expected_recipient=$4

            status=$(${pkgs.sops}/bin/sops filestatus "$file") || fail "$label filestatus failed"
            [ "$status" = '{"encrypted":true}' ] || fail "$label is not fully encrypted"
            actual_keys=$(${pkgs.yq-go}/bin/yq -o=json -I=0 \
              '[keys[] | select(. != "sops")] | sort' "$file")
            [ "$actual_keys" = "$expected_keys" ] || fail "$label has unexpected top-level secret keys"
            ${pkgs.yq-go}/bin/yq -e \
              '[to_entries[] | select(.key != "sops") | .value | (tag == "!!str" and test("^ENC\\["))] | all' \
              "$file" >/dev/null || fail "$label contains a plaintext secret value"
            [ "$(${pkgs.yq-go}/bin/yq -r '.sops.age | length' "$file")" = 1 ] || \
              fail "$label must contain exactly one age recipient"
            actual_recipient=$(${pkgs.yq-go}/bin/yq -r '.sops.age[].recipient' "$file")
            [ "$actual_recipient" = "$expected_recipient" ] || fail "$label recipient does not match .sops.yaml"
          }

          check_secret_file bootstrap "$bootstrap_file" \
            '["gpg-secret-key","jupiter-age-key","login-password","luks-passphrase","ssh-private-key"]' \
            "$management_recipient"
          check_secret_file runtime "$runtime_file" \
            '["smb-mars-shishi","tailscale-oauth-secret"]' "$runtime_recipient"
          touch $out
        '';

        # 秘密の初期化・配送・GPG import は、静的な暗号化済みファイルの検査だけでは
        # rollback、出力のredaction、配送先modeの退行を検出できない。テストが
        # 開発者のlogin PATHを偶然使わないよう、実行に必要なコマンドをすべて固定する。
        secrets-workflow-contract =
          pkgs.runCommand "secrets-workflow-contract"
            {
              src = ../.;
              nativeBuildInputs = with pkgs; [
                age
                bash
                coreutils
                diffutils
                findutils
                gawk
                git
                gnugrep
                gnupg
                gnused
                jq
                mkpasswd
                openssh
                ripgrep
                sops
                util-linux
              ];
            }
            ''
              bash "$src/scripts/secrets-workflow.test.sh" all
              touch $out
            '';

        # ロケール契約: 表示は英語、書式は日本の慣習。
        # SDDM の greeter も同じ値で固定する。nixos/desktop/kde.nix が
        # display-manager.service の environment へ i18n を写しているが、
        # その写しが消えても system 側の宣言だけは通ってしまうので、
        # 宣言が実際に unit へ届いているかをここで突き合わせる。
        #
        # 契約は 2 層に分かれている。system 側はリテラルと突き合わせて
        # ロケール方針そのものを固定し、greeter 側は期待値を i18n から導出して
        # 「写しが system と一致していること」だけを固定する。
        # こうすると方針のリテラルはこのファイルの 1 箇所にしか無いので、
        # locale.nix を変えたときに落ちるのは system 側の行だけになり、
        # 失敗メッセージが「方針を変えた」のか「写しがずれた」のかを区別できる。
        # 両側をリテラルで書くと同じ 5 つの値が 2 箇所に並び、片方だけ直して
        # 「greeter は system と同じ」の意味が壊れる余地が残る。
        #
        # 導出の副作用: extraLocaleSettings から例えば LC_TIME が消えると
        # greeter 側の期待値も "" になり、その行は空同士の比較で素通りする。
        # ただし同じ消失で system 側の LC_TIME が落ちるので、契約としては検出できる。
        locale-contract =
          let
            i18n = self.nixosConfigurations.jupiter.config.i18n;
            # unit ごと消えた場合も eval エラーではなく check の失敗として出したいので or {}。
            greeter =
              self.nixosConfigurations.jupiter.config.systemd.services.display-manager.environment or { };
          in
          pkgs.runCommand "locale-contract" { } ''
            ok=1
            check() {
              if [ "$2" != "$3" ]; then
                echo "$1: expected '$3' but got '$2'"
                ok=0
              fi
            }
            # 方針の固定: 期待値はここにしか無いリテラル。
            check defaultLocale "${i18n.defaultLocale}" "en_US.UTF-8"
            check LC_TIME "${i18n.extraLocaleSettings.LC_TIME or ""}" "en_DK.UTF-8"
            check LC_MONETARY "${i18n.extraLocaleSettings.LC_MONETARY or ""}" "ja_JP.UTF-8"
            check LC_PAPER "${i18n.extraLocaleSettings.LC_PAPER or ""}" "ja_JP.UTF-8"
            check LC_MEASUREMENT "${i18n.extraLocaleSettings.LC_MEASUREMENT or ""}" "ja_JP.UTF-8"

            # 写しの一致の固定: 期待値は system 側の i18n から導出する。
            # environment には PATH も入るが契約はロケールだけなので、キーを名指しで見る。
            check greeter.LANG "${greeter.LANG or ""}" "${i18n.defaultLocale}"
            check greeter.LC_TIME "${greeter.LC_TIME or ""}" "${i18n.extraLocaleSettings.LC_TIME or ""}"
            check greeter.LC_MONETARY "${greeter.LC_MONETARY or ""}" "${
              i18n.extraLocaleSettings.LC_MONETARY or ""
            }"
            check greeter.LC_PAPER "${greeter.LC_PAPER or ""}" "${i18n.extraLocaleSettings.LC_PAPER or ""}"
            check greeter.LC_MEASUREMENT "${greeter.LC_MEASUREMENT or ""}" "${
              i18n.extraLocaleSettings.LC_MEASUREMENT or ""
            }"
            [ "$ok" = 1 ] || exit 1
            touch $out
          '';

        # 新規インストール時の fcitx5 プロファイル契約。SKK は内部の Latin
        # モードで英数入力へ切り替えるため、別の keyboard-* 入力メソッドを
        # profile へ追加しない。Clipboard は有効のまま、現機の呼び出しキーと
        # 履歴件数を再現する。
        ime-contract =
          let
            fcitx5 = self.nixosConfigurations.jupiter.config.i18n.inputMethod.fcitx5;
            inputMethod = fcitx5.settings.inputMethod;
            clipboard = fcitx5.settings.addons.clipboard or { };
            show = value: if value == null then "null" else toString value;
          in
          pkgs.runCommand "ime-contract" { } ''
            ok=1
            check() {
              if [ "$2" != "$3" ]; then
                echo "$1: expected '$3' but got '$2'"
                ok=0
              fi
            }
            check defaultIM "${inputMethod."Groups/0".DefaultIM}" "skk"
            check item0 "${inputMethod."Groups/0/Items/0".Name}" "skk"
            check item0Layout "${inputMethod."Groups/0/Items/0".Layout}" "us"
            check profileEntries "${builtins.concatStringsSep "|" (builtins.attrNames inputMethod)}" \
              "GroupOrder|Groups/0|Groups/0/Items/0"
            check clipboardHistory "${show clipboard.globalSection."Number of entries"}" "5"
            check clipboardTrigger "${clipboard.sections.TriggerKey."0"}" "Control+Alt+Shift+C"
            [ "$ok" = 1 ] || exit 1
            touch $out
          '';

        # AC では自動 sleep を行わず、バッテリーでは電力を使い切る前に sleep する。
        # 画面消灯は sleep と独立して全プロファイルで有効にする。
        sleep-contract =
          let
            hm = self.nixosConfigurations.jupiter.config.home-manager.users.shishi;
            plasma = hm.programs.plasma;
            powerdevil = plasma.powerdevil;
            powerdevilrc = plasma.configFile.powerdevilrc;
            reloadPowerDevil = pkgs.writeText "reload-powerdevil-activation" (
              hm.home.activation.reloadPowerDevil.data or ""
            );
            pythonWithDbusMock = pkgs.python3.withPackages (pythonPackages: [
              pythonPackages.python-dbusmock
            ]);
            dbusDaemon = pkgs.writeShellScript "dbus-daemon-for-sleep-contract" ''
              args=()
              for arg in "$@"; do
                if [ "$arg" != "--session" ]; then
                  args+=("$arg")
                fi
              done
              exec ${pkgs.dbus}/bin/dbus-daemon \
                --config-file=${pkgs.dbus}/share/dbus-1/session.conf \
                "''${args[@]}"
            '';
            settingValue = section: key: ((powerdevilrc.${section}.${key} or { }).value or null);
            show = value: if value == null then "null" else toString value;
          in
          pkgs.runCommand "sleep-contract"
            {
              nativeBuildInputs = [
                pkgs.dbus
                pythonWithDbusMock
              ];
            }
            ''
              ok=1
              check() {
                if [ "$2" != "$3" ]; then
                  echo "$1: expected '$3' but got '$2'"
                  ok=0
                fi
              }
              check AC.autoSuspend.action "${show powerdevil.AC.autoSuspend.action}" "0"
              check AC.autoSuspend.idleTimeout "${show powerdevil.AC.autoSuspend.idleTimeout}" "null"
              check AC.turnOffDisplay.idleTimeout "${show powerdevil.AC.turnOffDisplay.idleTimeout}" "900"
              check AC.turnOffDisplay.enabled "${show (settingValue "AC/Display" "TurnOffDisplayWhenIdle")}" "1"
              check battery.autoSuspend.action "${show powerdevil.battery.autoSuspend.action}" "1"
              check battery.autoSuspend.idleTimeout "${show powerdevil.battery.autoSuspend.idleTimeout}" "3600"
              check battery.turnOffDisplay.idleTimeout "${show powerdevil.battery.turnOffDisplay.idleTimeout}" "900"
              check battery.turnOffDisplay.enabled "${show (settingValue "Battery/Display" "TurnOffDisplayWhenIdle")}" "1"
              check lowBattery.autoSuspend.action "${show powerdevil.lowBattery.autoSuspend.action}" "1"
              check lowBattery.autoSuspend.idleTimeout "${show powerdevil.lowBattery.autoSuspend.idleTimeout}" "300"
              check lowBattery.turnOffDisplay.idleTimeout "${show powerdevil.lowBattery.turnOffDisplay.idleTimeout}" "900"
              check lowBattery.turnOffDisplay.enabled "${show (settingValue "LowBattery/Display" "TurnOffDisplayWhenIdle")}" "1"
              check reloadPowerDevil.after "${
                builtins.concatStringsSep "|" (hm.home.activation.reloadPowerDevil.after or [ ])
              }" \
                "configure-plasma"
              [ "$ok" = 1 ] || exit 1

              dbus-run-session --dbus-daemon=${dbusDaemon} -- \
                ${pythonWithDbusMock}/bin/python -m dbusmock \
                org.kde.Solid.PowerManagement \
                /org/kde/Solid/PowerManagement \
                org.kde.Solid.PowerManagement \
                -e ${pkgs.bash}/bin/bash -euc '
                  set -o pipefail
                  busctl=${pkgs.systemd}/bin/busctl
                  "$busctl" --user call \
                    org.kde.Solid.PowerManagement \
                    /org/kde/Solid/PowerManagement \
                    org.freedesktop.DBus.Mock \
                    AddMethod sssss \
                    "" refreshStatus "" "" ""

                  run() {
                    if [[ -v DRY_RUN ]]; then
                      echo "$@"
                    else
                      "$@"
                    fi
                  }

                  . ${reloadPowerDevil}
                  DRY_RUN=1
                  . ${reloadPowerDevil}

                  calls="$("$busctl" --user call \
                    org.kde.Solid.PowerManagement \
                    /org/kde/Solid/PowerManagement \
                    org.freedesktop.DBus.Mock \
                    GetMethodCalls s refreshStatus)"
                  case "$calls" in
                    "a(tav) 1 "*) ;;
                    *)
                      echo "PowerDevil configuration was not reloaded exactly once: $calls" >&2
                      exit 1
                      ;;
                  esac
                '
              touch $out
            '';

        # 通知トーストはパネル上の通知ウィジェット位置ではなく、固定した画面右上へ出す。
        # Plasma の PopupPosition 列挙では TopRight が 3。
        notification-contract =
          let
            configFile =
              self.nixosConfigurations.jupiter.config.home-manager.users.shishi.programs.plasma.configFile;
            notificationConfig = configFile.plasmanotifyrc or { };
            notifications = notificationConfig.Notifications or { };
            popupPosition = (notifications.PopupPosition or { }).value or null;
            show = value: if value == null then "null" else toString value;
          in
          pkgs.runCommand "notification-contract" { } ''
            if [ "${show popupPosition}" != "3" ]; then
              echo "notifications.popupPosition: expected '3' but got '${show popupPosition}'"
              exit 1
            fi
            touch $out
          '';

        # ブート契約: lanzaboote が systemd-boot を置き換えていること。
        # bootloader の取り違えは起動して初めて分かるので、eval で固定する。
        boot-contract =
          let
            inherit (pkgs) lib;
            cfg = self.nixosConfigurations.jupiter.config;
            b = if cfg.boot.lanzaboote.enable then "true" else "false";
            sdb = if cfg.boot.loader.systemd-boot.enable then "true" else "false";
            # hosts/jupiter/default.nix の authorizedKeys 生成と文字どおり一致させる。
            # ここだけの都合でずらすと、以下の 2 check がどちらも無意味な値どうしの
            # 比較になり気づけない。
            initrdKeyPrefix = ''command="systemctl default" '';
            initrdKeys = cfg.boot.initrd.network.ssh.authorizedKeys;
            bodyKeys = cfg.users.users.shishi.openssh.authorizedKeys.keys;
            # 区切りに改行を使う。authorizedKeys の 1 エントリは 1 行の文字列
            # (type + base64 + comment)なので改行は値の内部に現れず、
            # 連結しても「本数がずれた 2 つの列」が同じ文字列に化けることはない。
            joinKeys = lib.concatStringsSep "\n";
            # initrd の DHCP 定義は **networking.useDHCP に連動して消える**。
            # 以前は useDHCP(既定 true)由来の nixpkgs デフォルト
            # "99-ethernet-default-dhcp" が initrd 側にも生成されるので任せて
            # いたが、networking.networkmanager.enable = true が useDHCP を
            # false にするため、その生成が止まる(実測: NM 有効で
            # boot.initrd.systemd.network.networks が {} になり、
            # NM を mkForce false に戻すと 2 定義が返る)。
            #
            # 定義が無いと、ドライバが入っていてリンクが上がり sshd が listen
            # していてもアドレスが付かない。外形は NIC ドライバ欠落と同じで、
            # ビルドも起動も成功するため、気づくのは復旧が要る場面になる。
            # だから config 側の宣言をここで固定する。
          in
          pkgs.runCommand "boot-contract" { } ''
            ok=1
            check() {
              if [ "$2" != "$3" ]; then
                echo "$1: expected '$3' but got '$2'"
                ok=0
              fi
            }
            check lanzaboote.enable "${b}" "true"
            check systemd-boot.enable "${sdb}" "false"
            check pkiBundle "${toString cfg.boot.lanzaboote.pkiBundle}" "/var/lib/sbctl"
            check kernel.sysctl.arp_ignore.all "${
              toString (cfg.boot.kernel.sysctl."net.ipv4.conf.all.arp_ignore" or "missing")
            }" "1"
            check kernel.sysctl.arp_ignore.default "${
              toString (cfg.boot.kernel.sysctl."net.ipv4.conf.default.arp_ignore" or "missing")
            }" "1"
            check kernel.sysctl.arp_announce.all "${
              toString (cfg.boot.kernel.sysctl."net.ipv4.conf.all.arp_announce" or "missing")
            }" "2"
            check kernel.sysctl.arp_announce.default "${
              toString (cfg.boot.kernel.sysctl."net.ipv4.conf.default.arp_announce" or "missing")
            }" "2"
            # 復旧経路。initrd.network.enable が無いと ssh.enable は no-op になる。
            check initrd.network.enable "${if cfg.boot.initrd.network.enable then "true" else "false"}" "true"
            check initrd.ssh.enable "${if cfg.boot.initrd.network.ssh.enable then "true" else "false"}" "true"
            check initrd.ssh.port "${toString cfg.boot.initrd.network.ssh.port}" "2222"
            # 実際に復旧経路を壊した箇所(実測 2026-08-21): initrd に NIC
            # ドライバが無いと、sshd が listen していてもリンクが上がらず
            # 到達不能になる。VM のドライバ名は e1000。availableKernelModules
            # は「含まれていれば適用される」意味論なので、実機のドライバ名が
            # 確定しても hosts/jupiter/default.nix 側の e1000 は消さず追記する
            # (この check は e1000 が引き続き present であることを要求する。
            # e1000 は VM リハーサル用のドライバで、これを消すと VM での
            # 検証経路が壊れるため残す)。
            check initrd.availableKernelModules.e1000 "${
              if builtins.elem "e1000" cfg.boot.initrd.availableKernelModules then "present" else "missing"
            }" "present"
            # 下の initrd 系の条件は systemd initrd が前提。boot.initrd.systemd.enable
            # を落とすと scripted initrd に戻り、network.networks も
            # crypttabExtraOpts の tpm2-device も initrd に反映されない。
            # にもかかわらず attrset の値としては読めてしまうので、土台を先に見る。
            # これが無いと、下の条件は「見ているように見えて何も守らない」。
            check initrd.systemd.enable "${if cfg.boot.initrd.systemd.enable then "true" else "false"}" "true"
            # NIC ドライバがあってもこれが無いと IP が来ない(上のコメント参照)。
            check initrd.dhcpNetwork "${
              if cfg.boot.initrd.systemd.network.networks ? "99-ethernet-default-dhcp" then
                "present"
              else
                "missing"
            }" "present"
            check initrd.dhcpNetwork.match "${
              cfg.boot.initrd.systemd.network.networks."99-ethernet-default-dhcp".matchConfig.Type or ""
            }" "ether"
            check initrd.dhcpNetwork.dhcp "${
              cfg.boot.initrd.systemd.network.networks."99-ethernet-default-dhcp".networkConfig.DHCP or ""
            }" "yes"
            # これが無いと SSH で入る前に root デバイスの unit がタイムアウトする。
            check root.deviceTimeout "${
              if builtins.elem "x-systemd.device-timeout=infinity" cfg.fileSystems."/".options then
                "present"
              else
                "missing"
            }" "present"
            # TPM の取得口。これが無いと enroll しても initrd が TPM を見に行かない。
            check luks.tpm2 "${
              if builtins.elem "tpm2-device=auto" cfg.boot.initrd.luks.devices.cryptroot.crypttabExtraOpts then
                "present"
              else
                "missing"
            }" "present"
            # settings.keyFile が復活すると、この値がそのまま
            # boot.initrd.luks.devices.cryptroot.keyFile へ伝播し、
            # systemd-cryptsetup の attach_luks_or_plain_or_bitlk_by_tpm2 が
            # key_file 非 null を見て LUKS2 ヘッダ内のトークン探索
            # (attach_luks2_by_tpm2_via_plugin / find_tpm2_auto_data)を一切試さなく
            # なる。実機の initrd に /tmp/secret.key は存在しないため、これが起きると
            # 起動時は毎回失敗して対話パスフレーズにフォールバックし、TPM 自動解錠が
            # 黙って壊れる。インストール時の非対話鍵は settings ではなくトップレベルの
            # passwordFile(hosts/jupiter/disko.nix)で渡す契約なので、ここでは
            # keyFile が null のままであることだけを固定する。
            check luks.keyFile.null "${
              if cfg.boot.initrd.luks.devices.cryptroot.keyFile == null then "null" else "non-null"
            }" "null"
            # 上の keyFile.null は起動時の契約(非対話 TPM 解錠)だけを固定していて、
            # インストール時の契約は別に固定しないと守れない。disko の
            # lib/types/luks.nix (askPassword のデフォルト式) を見ると、
            # settings.keyFile も passwordFile も設定しなければ askPassword は
            # 既定で true に戻り、nixos-anywhere 実行中に disko が
            # `IFS= read -r -s password` で対話プロンプトを出して非対話インストールが
            # 壊れる。hosts/jupiter/disko.nix の passwordFile を消す/null化する変更は
            # settings.keyFile に触れないので上の keyFile.null 側は green のまま
            # 通ってしまい、この askPassword 側でしか壊れたことが見えない。
            check disko.askPassword "${
              if
                self.nixosConfigurations.jupiter.config.disko.devices.disk.main.content.partitions.luks.content.askPassword
              then
                "true"
              else
                "false"
            }" "false"
            # authorizedKeys は本体(nixos/users.nix)の宣言から command= だけ足して
            # 生成する参照方式(リテラル 2 重化を避けるため)。この契約を守る check は
            # 本数の一致 1 本では書けない。実装が `map` である限り
            # length (map f xs) == length xs は恒等式で必ず真になり、本数だけを見る
            # check は絶対に落ちない。同時に、authorizedKeys を本体と同数の
            # リテラル(例: 差し替え忘れの古い鍵)へ書き戻す退行も本数は変わらないため
            # 素通りする。
            #
            # かといって「prefix を剥がしたら本体と一致する」の 1 本にもできない。
            # lib.removePrefix は prefix が無いとき文字列をそのまま返すので、
            # command= を落とした実装でも「剥がした結果 == 本体」が成立してしまい、
            # prefix の脱落そのものは検出できない。
            #
            # そこで次の 2 つを別々に検査する。
            # 1) initrd の全鍵が command= prefix を持つこと。
            # 2) prefix を剥がした結果が、本体の鍵列と順序込みで完全一致すること
            #    (本数も暗黙に一致する。列の長さが違えば連結結果も一致しない)。
            # 綴り(公開鍵の中身)は本体の値をそのまま使って比較するだけで、
            # ここへ鍵文字列を書き写す 2 重化にはならない。
            #
            # 検出できないもの: initrd と本体が「たまたま」偶然一致する形で
            # 両方とも独立に書き換えられた場合(その場合そもそも参照方式ですらない)。
            check initrd.ssh.authorizedKeys.prefixed "${
              if lib.all (lib.hasPrefix initrdKeyPrefix) initrdKeys then "true" else "false"
            }" "true"
            check initrd.ssh.authorizedKeys.match "${joinKeys (map (lib.removePrefix initrdKeyPrefix) initrdKeys)}" "${joinKeys bodyKeys}"
            # 上の 2 本は initrdKeys が空リストのとき vacuous に通る。lib.all は
            # 空リストに対して true を返し、joinKeys [] は両辺とも "" になって
            # 一致するので、鍵がゼロ本でも prefixed / match は両方 green になる。
            # authorizedKeys ゼロ本の initrd は「見た目は健全だが誰も入れない」
            # 遠隔復旧経路そのものであり、この 2 本はまさにその締め出しを検出する
            # ために置かれている。non-empty をここで別途固定しないと締め出しが
            # 素通りする。
            check initrd.ssh.authorizedKeys.nonEmpty "${
              if initrdKeys != [ ] then "nonempty" else "empty"
            }" "nonempty"
            [ "$ok" = 1 ] || exit 1
            touch $out
          '';

        # SKK の打鍵挙動の契約。libskk 同梱の CLI エミュレータ(bin/skk)に
        # キーイベント列を流し、確定出力と preedit を照合する。
        # GUI もセッションも要らないので nix flake check に乗る。
        #
        # 期待値の空文字は "" で書く。Nix のインデント文字列では '' が終端記号なので、
        # シェルの空文字を '' と書くとここで文字列が切れる。
        skk-rom-kana = pkgs.runCommand "skk-rom-kana" { nativeBuildInputs = [ pkgs.libskk ]; } ''
          export HOME=$TMPDIR
          export XDG_CONFIG_HOME=$TMPDIR/.config
          mkdir -p "$XDG_CONFIG_HOME/libskk"
          cp -r ${skkRuleDir} "$XDG_CONFIG_HOME/libskk/rules"
          chmod -R u+w "$XDG_CONFIG_HOME/libskk/rules"

          ok=1
          # 引数: 説明, キー列, 期待 output, 期待 preedit
          # 変数名に out を使わないこと: runCommand の $out(出力 store path)を
          # 上書きしてしまい、全ケースが通っても最後の touch $out が落ちる。
          case_() {
            got=$(printf '%s\n' "$2" | skk -r StickyShift 2>/dev/null | tail -1)
            gotOut=$(printf '%s' "$got" | ${pkgs.jq}/bin/jq -r '.output')
            gotPre=$(printf '%s' "$got" | ${pkgs.jq}/bin/jq -r '.preedit')
            if [ "$gotOut" != "$3" ] || [ "$gotPre" != "$4" ]; then
              echo "FAIL $1: keys=[$2]"
              echo "  expected output=[$3] preedit=[$4]"
              echo "  actual   output=[$gotOut] preedit=[$gotPre]"
              ok=0
            fi
          }

          # 目標: 数字の直後の記号を半角のまま出す
          case_ date    '2 0 2 6 minus 0 8 minus 1 2' '2026-08-1' '2'
          case_ decimal '3 period 1 4'                '3.1'       '4'
          case_ comma   '1 comma 0 0 0'               '1,00'      '0'
          case_ colon   '1 2 colon 3 0'               '12:3'      '0'
          case_ slash   '0 slash 5'                   '0/'        '5'

          # 回帰: 既存の入力を壊していない
          case_ digits  '1 2 3'         '12'     '3'
          case_ mixed   '1 a'           '1あ'    ""
          case_ kana    'a i u'         'あいう' ""
          case_ chouon  'k a minus'     'かー'   ""
          case_ plus    '1 plus 2'      '1+'     '2'
          case_ grave   '1 grave 2'     '1`'     '2'
          case_ abbrev  'slash a'       ""       '▽a'
          case_ sticky  'semicolon a i' ""       '▽あい'

          [ "$ok" = 1 ] || exit 1
          touch $out
        '';

        # rom-kana 差分テーブルの文字被覆。
        # skk-rom-kana が「打てば期待どおり出る」ことを代表例で見るのに対し、
        # こちらは「そもそも全部の文字が定義されているか」を網羅で見る。
        # 被覆に 1 文字でも穴があると、その文字を数字の直後に打った瞬間に
        # libskk が保留中の数字を破棄する(実際にバッククォートだけが抜けていた)。
        #
        # 期待値の 95 文字は rules.nix から取らずここへ独立に書く。
        # rules.nix 由来の値どうしを突き合わせても循環していて何も検査できない。
        # Nix にはコード値から文字を作る関数が無いので、ASCII 印字可能文字
        # (0x20 スペース 〜 0x7E チルダ)はリテラルで並べるほかない。
        #
        # 判定は Nix 側で済ませ、結果は passAsFile でファイルとして渡す
        # (nix-caches-sync と同じ渡し方)。問題文字には \ " ` $ が入りうるので、
        # シェルの引数やインデント文字列へ直接載せると別物に化ける
        # (バッククォートはコマンド置換になる)。
        skk-rom-kana-coverage =
          let
            inherit (pkgs) lib;
            inherit (skkRules.charSets) digits keepAscii others;

            expectedAscii = lib.stringToCharacters " !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~";

            # 問題文字は可能ならコード値を添えて出す。空白のように目で見えない
            # 文字を 0x20 と名指しするのが目的。
            #
            # charToInt は ASCII の表しか持たず、0x80 以上のバイトを渡すと
            # attribute missing で評価ごと死ぬ(実測。builtins.tryEval でも捕まらず、
            # lib.strings.asciiTable も export されていないので存在確認もできない)。
            # others へ非 ASCII が紛れると stringToCharacters がバイトへ分解して
            # この経路に入るため、expectedAscii への所属ではなく
            # リテラルに依存しない判定で入口を塞ぐ。
            # builtins.match は任意のバイトに対して null を返すだけで throw しない(実測)。
            isPrintableAscii = c: builtins.match "[ -~]" c != null;
            showChar =
              c:
              if isPrintableAscii c then
                "0x${lib.fixedWidthString 2 "0" (lib.toHexString (lib.strings.charToInt c))}[${c}]"
              else
                "[${c}]";
            show = lib.concatMapStringsSep " " showChar;

            covered = keepAscii ++ others;
            dupsIn = cs: lib.filter (c: lib.count (x: x == c) cs > 1) (lib.unique cs);

            missing = lib.filter (c: !(lib.elem c covered)) expectedAscii;
            extra = lib.filter (c: !(lib.elem c expectedAscii)) covered;
            overlap = lib.filter (c: lib.elem c others) keepAscii;

            # 期待値リテラルそのものの自己検査。他の判定はすべてこれを基準にするので、
            # ここが崩れると check は静かに嘘をつく。個数だけでなく
            # 「0x20 から 0x7E が順に並んでいる」ことまで見る。
            # && の右辺は遅延評価なので、非 ASCII 混入時に charToInt へは届かない。
            literalOk =
              lib.all isPrintableAscii expectedAscii
              && map lib.strings.charToInt expectedAscii == lib.range 32 126;

            # エントリ数は assert する定数ではなく導出値。digits の要素数 x 覆った
            # 文字数で、どちらの長さもここには書かない。romKana は listToAttrs が
            # 重複キーを畳むので、digits か covered に重複があればここが必ずずれる
            # (covered 側はどの文字かを上の行が名指しする)。
            #
            # ここが見るのはキーの本数だけで、綴り方は見ない。既存の skk-rom-kana
            # check は代表的な打鍵を 13 通り試すだけなので、950 キー全部の綴りを
            # 保証するものではない(例: キーを "${d}${s}" から "${s}${d}" へ
            # 入れ替えても本数は変わらず、どちらの check も通ってしまう)。
            expectedEntries = builtins.length digits * builtins.length covered;
            actualEntries = builtins.length (builtins.attrNames skkRules.romKana);

            # リテラルが壊れているときは他を並べない。missing / extra は壊れた基準
            # からの派生値で、rules.nix 側の問題に見えてしまう
            # (実測: リテラルから ~ を落とすと ~ が「印字可能外」と報告された)。
            problems =
              if !literalOk then
                [
                  "expectedAscii literal is corrupt: must be exactly 0x20..0x7E in order (other checks skipped)"
                ]
              else
                lib.optional (missing != [ ]) "not covered by keepAscii+others: ${show missing}"
                ++ lib.optional (extra != [ ]) "outside ASCII printable: ${show extra}"
                ++ lib.optional (overlap != [ ]) "in both keepAscii and others: ${show overlap}"
                ++ lib.optional (dupsIn keepAscii != [ ]) "duplicated within keepAscii: ${show (dupsIn keepAscii)}"
                ++ lib.optional (dupsIn others != [ ]) "duplicated within others: ${show (dupsIn others)}"
                ++ lib.optional (
                  expectedEntries != actualEntries
                ) "romKana entries: expected ${toString expectedEntries} but got ${toString actualEntries}";
          in
          pkgs.runCommand "skk-rom-kana-coverage"
            {
              report = lib.concatMapStrings (p: p + "\n") problems;
              passAsFile = [ "report" ];
            }
            ''
              if [ -s "$reportPath" ]; then
                echo "skk rom-kana coverage is broken:"
                # 各行は問題文字を生のまま含む。印字可能 ASCII には 0xNN が付くが、
                # 制御文字と非 ASCII バイトには付かない(上の showChar 参照)ので、
                # -A(= -vET)で可視化する。-v だけでは TAB と LF が素通しになり
                # (実測)、LF が混入すると報告が黙って複数行へ割れて読めなくなる。
                # -A なら TAB は ^I、非 ASCII は M-xx、行末は $ で見える。
                cat -A "$reportPath"
                exit 1
              fi
              touch $out
            '';

        # 初回インストールの唯一のユーザー手順と config の秘密境界を固定する。
        # 秘密の抽出、tmpfs、配送先、mode は workflow test が実装に対して検査する。
        # ここでは runbook がその wrapper を迂回していないことと、ログイン資格情報を
        # public repo や Nix store に置かない config を検査する。
        install-keys-contract =
          let
            inherit (pkgs) lib;
            cfg = self.nixosConfigurations.jupiter.config;
            u = cfg.users.users.shishi;
            gid = cfg.users.groups.${u.group}.gid;
            # この repo は public なので、shishi のパスワードを構成に書かない
            # (見ているのは shishi の分だけで、他ユーザーは対象外)。
            # hashedPasswordFile が埋まっているかだけを見ると、initialPassword を
            # 足し戻した変更を捕まえられないので、値を保持する option を直接見る。
            # 値を保持するのはこの 4 つで、hashedPasswordFile はパスなので入らない。
            #
            # ただし hashedPasswordFile に pkgs.writeText や ./secret のような
            # store path を渡すと、この 4 つはすべて null のままリテラルが
            # public repo へ入る。store の下を指していないことも見る。
            literalPassword =
              u.initialPassword != null
              || u.initialHashedPassword != null
              || u.hashedPassword != null
              || u.password != null
              || (
                u.hashedPasswordFile != null && lib.hasPrefix builtins.storeDir (toString u.hashedPasswordFile)
              );
            hashRel = if u.hashedPasswordFile == null then null else lib.removePrefix "/" u.hashedPasswordFile;
            requiredInstallRunbookText = [
              "nix run .#nixos-anywhere -- --flake .#jupiter --target-host root@<target> --ssh-port <port> --phases disko"
              "nix run .#nixos-anywhere -- --flake .#jupiter --target-host root@<target> --ssh-port <port> --phases install"
            ];
            requiredSecretsRunbookText = [
              "nix run .#init-secrets"
              "secrets/management-age-key.txt"
              "git add .sops.yaml secrets/bootstrap.yaml secrets/runtime.yaml"
            ];
            obsoleteRunbookText = [
              "secrets/luks-passphrase"
              "secrets/login-password"
              "secrets/extra-files"
              "check-install-secrets"
              "--extra-files"
              "gpg --batch --import"
            ];
          in
          pkgs.runCommand "install-keys-contract"
            {
              installRunbook = builtins.readFile ../docs/jupiter-install-runbook.md;
              readme = builtins.readFile ../README.md;
              secretsRunbook = builtins.readFile ../docs/jupiter-secrets-runbook.md;
              secureBootRunbook = builtins.readFile ../docs/jupiter-secure-boot-runbook.md;
              passAsFile = [
                "installRunbook"
                "readme"
                "secretsRunbook"
                "secureBootRunbook"
              ];
            }
            ''
              ok=1
              ${lib.concatMapStringsSep "\n" (required: ''
                grep -qF -- '${required}' "$installRunbookPath" || {
                  echo "install runbook に必要な手順が無い。期待: ${required}"
                  ok=0
                }
              '') requiredInstallRunbookText}
              ${lib.concatMapStringsSep "\n" (required: ''
                grep -qF -- '${required}' "$secretsRunbookPath" || {
                  echo "secrets runbook に必要な手順が無い。期待: ${required}"
                  ok=0
                }
              '') requiredSecretsRunbookText}
              ${lib.concatMapStringsSep "\n" (obsolete: ''
                if grep -qF -- '${obsolete}' \
                  "$readmePath" \
                  "$installRunbookPath" \
                  "$secretsRunbookPath" \
                  "$secureBootRunbookPath"; then
                  echo "ユーザー向け文書に廃止した平文・手動配送手順が残っている: ${obsolete}"
                  ok=0
                fi
              '') obsoleteRunbookText}
              check() {
                if [ "$2" != "$3" ]; then
                  echo "$1: expected '$3' but got '$2'"
                  ok=0
                fi
              }
              check users.users.shishi.uid '${toString u.uid}' '1000'
              check users.users.shishi.group '${u.group}' 'users'
              check users.groups.users.gid '${toString gid}' '100'
              ${lib.optionalString literalPassword ''
                echo "users.users.shishi のパスワードが repo の中にある(値を持つ option か、store path を指す hashedPasswordFile)。この repo は public"
                ok=0
              ''}
              ${lib.optionalString (hashRel == null) ''
                echo "users.users.shishi.hashedPasswordFile が無いので、鍵と一緒に運ぶ対象が config から決まらず、手順書との対応を検査できない"
                ok=0
              ''}
              ${lib.optionalString (hashRel != null) ''
                check users.users.shishi.hashedPasswordFile '${hashRel}' 'var/lib/secrets/shishi-password-hash'
              ''}
              [ "$ok" = 1 ] || exit 1
              touch $out
            '';

        # direnv allow を root flake の cache 設定に対する信頼境界にする。
        flake-config-boundary =
          let
            findFlakes =
              dir:
              let
                entries = builtins.readDir dir;
              in
              pkgs.lib.concatMap (
                name:
                let
                  path = dir + "/${name}";
                in
                if entries.${name} == "directory" then
                  findFlakes path
                else
                  pkgs.lib.optional (entries.${name} == "regular" && name == "flake.nix") path
              ) (builtins.attrNames entries);
            flakes = map (path: {
              inherit path;
              config = (import path).nixConfig or { };
            }) (findFlakes ../.);
            selfApprovalViolations = builtins.filter (
              flake: builtins.hasAttr "accept-flake-config" flake.config
            ) flakes;
            approvedConfigPaths = map toString [
              ../flake.nix
              ../templates/ruby/flake.nix
            ];
            unexpectedConfigViolations = builtins.filter (
              flake: flake.config != { } && !(builtins.elem (toString flake.path) approvedConfigPaths)
            ) flakes;
            rootConfig = (import ../flake.nix).nixConfig or { };
            rubyConfig = (import ../templates/ruby/flake.nix).nixConfig or { };
            expectedKeys = [
              "extra-substituters"
              "extra-trusted-public-keys"
            ];
          in
          pkgs.runCommand "flake-config-boundary" { } ''
            ok=1
            ${pkgs.lib.optionalString (builtins.attrNames rootConfig != expectedKeys) ''
              echo "root flake nixConfig must contain only project cache settings"
              ok=0
            ''}
            ${pkgs.lib.optionalString
              (rootConfig."extra-substituters" or [ ] != builtins.tail caches.substituters)
              ''
                echo "root flake substituters do not match shared cache settings"
                ok=0
              ''
            }
            ${pkgs.lib.optionalString
              (rootConfig."extra-trusted-public-keys" or [ ] != builtins.tail caches.trustedPublicKeys)
              ''
                echo "root flake public keys do not match shared cache settings"
                ok=0
              ''
            }
            ${pkgs.lib.optionalString (builtins.attrNames rubyConfig != expectedKeys) ''
              echo "Ruby template nixConfig must contain only its project cache settings"
              ok=0
            ''}
            ${pkgs.lib.optionalString
              (rubyConfig."extra-substituters" or [ ] != [ (pkgs.lib.last caches.substituters) ])
              ''
                echo "Ruby template substituter does not match its project cache"
                ok=0
              ''
            }
            ${pkgs.lib.optionalString
              (rubyConfig."extra-trusted-public-keys" or [ ] != [ (pkgs.lib.last caches.trustedPublicKeys) ])
              ''
                echo "Ruby template public key does not match its project cache"
                ok=0
              ''
            }
            ${pkgs.lib.optionalString (selfApprovalViolations != [ ]) ''
              echo "flake nixConfig must not approve itself with accept-flake-config"
              ${pkgs.lib.concatMapStringsSep "\n" (
                flake: "echo ${pkgs.lib.escapeShellArg (toString flake.path)}"
              ) selfApprovalViolations}
              ok=0
            ''}
            ${pkgs.lib.optionalString (unexpectedConfigViolations != [ ]) ''
              echo "only the root and Ruby template flakes may define nixConfig"
              ${pkgs.lib.concatMapStringsSep "\n" (
                flake: "echo ${pkgs.lib.escapeShellArg (toString flake.path)}"
              ) unexpectedConfigViolations}
              ok=0
            ''}
            [ "$ok" = 1 ] || exit 1
            touch $out
          '';
      };
    };
}
