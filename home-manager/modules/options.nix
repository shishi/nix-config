{ lib, ... }:

{
  options.myConfig = {
    hasGui = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether this is a GUI environment. Set to false for headless servers.";
    };
  };
}
