{pkgs, ...}: let
  # Override the nixpkgs `bilibili` package to use the `continuous` release
  # from msojocs/bilibili-linux, which fixes the white-screen issue.
  version = "1.17.9.4828-continuous";
  bilibili-continuous = pkgs.bilibili.overrideAttrs (old: {
    inherit version;
    src = pkgs.fetchurl {
      url = "https://github.com/msojocs/bilibili-linux/releases/download/continuous/io.github.msojocs.bilibili_${version}_amd64.deb";
      hash = "sha256-p5xHbCiOSSonxxMXNVWymdRm5AJ26Kx1iYHLKqCDNOQ=";
    };
  });
in {
  environment.systemPackages = [bilibili-continuous];
}
