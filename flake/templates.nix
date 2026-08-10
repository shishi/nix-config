{ ... }:
{
  flake.templates = {
    basic = {
      path = ../templates/basic;
      description = "Basic development shell template";
    };
    rust = {
      path = ../templates/rust;
      description = "Rust development template (fenix toolchain)";
    };
  };
}
