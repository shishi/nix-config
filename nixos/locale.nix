{ ... }:
{
  # 表示言語は英語。書式・単位・通貨だけ日本の慣習へ寄せる。
  # LC_TIME は日本式にして、Dolphin を含む GUI とログの日付を年月日順へ揃える。
  # 表示言語は LANG=en_US のままなので、UI 自体は英語になる。
  i18n.defaultLocale = "en_US.UTF-8";
  i18n.extraLocaleSettings = {
    LC_TIME = "ja_JP.UTF-8";
    LC_MONETARY = "ja_JP.UTF-8"; # 円記号
    LC_PAPER = "ja_JP.UTF-8"; # A4
    LC_MEASUREMENT = "ja_JP.UTF-8"; # メートル法
  };

  # i18n.supportedLocales は書かない。nixpkgs の i18n モジュールは
  # extraLocaleSettings の各値から生成対象ロケールを導出する(aggregatedLocales)ので
  # ja_JP.UTF-8 は自動的に生成される。手で書くと二重管理になる。

  time.timeZone = "Asia/Tokyo";
}
