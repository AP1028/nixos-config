# Bottles on aarch64 (Asahi).
#
# Neither of the two obvious install paths works on this platform:
#
#   * Flathub's com.usebottles.bottles is published for x86_64 only (bundle
#     app/com.usebottles.bottles/x86_64/stable, SDK org.gnome.Sdk/x86_64/50),
#     so modules/packages/flatpak-bottles.nix — which the asusg16 uses —
#     cannot be reused here.
#   * nixpkgs' `bottles` and `bottles-unwrapped` fail to *evaluate* on
#     aarch64-linux: the wrapper is a buildFHSEnv with multiArch = true, i.e.
#     it pulls in pkgsi686Linux, and the i686 package set only exists on the
#     x86 family ("i686 Linux package set can only be used with the x86
#     family").
#
# Upstream's ARM64 packaging is the cpak (OCI image) release, so this enables
# the cpak runtime and installs a wrapper that runs Bottles *inside muvm*.
#
# Why muvm: this host has 16 KiB pages and FEX needs 4 KiB, so the Windows side
# only emulates correctly in muvm's microVM — the same reason
# programs.steam-asahi exists. packages/bottles-asahi.nix carries the details,
# including why cpak's installation has to live on a loop-mounted ext4 image
# rather than the guest's virtiofs root.
#
# Usage (see docs/bottles-asahi.md):
#
#   bottles-asahi-install     # first run: fetch Bottles into the guest store
#   bottles-asahi             # launch it inside the 4K-page microVM
#   bottles-asahi --install   # later: update it
{
  config,
  pkgs,
  ...
}: {
  services.cpak.enable = true;

  environment.systemPackages = [
    (pkgs.callPackage ../../packages/bottles-asahi.nix {
      inherit (config.users.users.${config.local.username}) home;
      # cpak's own module package (flake input, currently 2.14.2), not
      # nixpkgs' `cpak` (2.13.3): the guest store must be written and read by
      # one version, and only the module package carries cpak's system
      # authority assets.
      cpak = config.services.cpak.package;
    })
  ];
}
