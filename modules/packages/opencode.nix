{
  config,
  lib,
  pkgs,
  ...
}: {
  environment.systemPackages = with pkgs; [
    opencode
  ];
  environment.sessionVariables = {
    OPENCODE_ENABLE_EXA = "1";
  };
}
