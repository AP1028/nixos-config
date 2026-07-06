{
  config,
  lib,
  pkgs,
  ...
}: let
  # 32-bit x86 package set only exists on the x86 family.
  supports32Bit = pkgs.stdenv.hostPlatform.isx86;
in {
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = supports32Bit;
    pulse.enable = true;
  };

  environment.systemPackages = lib.optionals supports32Bit (with pkgs.pkgsi686Linux; [
    alsa-lib
    pipewire
    libpulseaudio
  ]);
}
