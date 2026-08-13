{ ... }:
{
  # 表示言語は英語。書式・単位・通貨だけ日本の慣習へ寄せる。
  # LC_TIME に en_DK を選ぶのは ISO 8601(YYYY-MM-DD)と 24 時制が得られ、
  # ログのタイムスタンプと表記が揃うため。ja_JP だと 2026年08月13日 形式が
  # 混ざり、英語 UI の中で浮く。
  i18n.defaultLocale = "en_US.UTF-8";
  i18n.extraLocaleSettings = {
    LC_TIME = "en_DK.UTF-8";
    LC_MONETARY = "ja_JP.UTF-8"; # 円記号
    LC_PAPER = "ja_JP.UTF-8"; # A4
    LC_MEASUREMENT = "ja_JP.UTF-8"; # メートル法
  };

  # i18n.supportedLocales は書かない。nixpkgs の i18n モジュールは
  # extraLocaleSettings の各値から生成対象ロケールを導出する(aggregatedLocales)ので
  # en_DK.UTF-8 は自動的に生成される。手で書くと二重管理になる。

  time.timeZone = "Asia/Tokyo";
}
