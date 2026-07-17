{
  pkgs,
  inputs,
  ...
}: {
  nixpkgs.overlays = [
    inputs.nix-gaming-edge.overlays.proton-cachyos
  ];

  # Steam with Proton GE and CJK font support inside the runtime
  programs.steam = {
    enable = true;

    package = pkgs.steam.override {
      extraPkgs = pkgs: with pkgs; [
        attr # fixes libattr.so.1 ATTR_1.3 not found in Steam runtime
        bubblewrap # for steamwebhelper nvidia wrapper
      ];
      extraProfile = ''
        # Wrap steamwebhelper with bwrap to hide nvidia devices (iGPU-only)
        WEBHELPER="$HOME/.local/share/Steam/ubuntu12_64/steamwebhelper"
        if [ -f "$WEBHELPER" ] && [ -x "$WEBHELPER" ] && ! grep -qF 'steamwebhelper.real' "$WEBHELPER" 2>/dev/null; then
          mv "$WEBHELPER" "$WEBHELPER.real"
          cat > "$WEBHELPER" << 'CEFWRAP'
#!/bin/sh
set -e
DIR="$(dirname "$0")"
exec bwrap \
  --dev-bind / / \
  --dev-bind /dev/null /dev/nvidia0 \
  --dev-bind /dev/null /dev/nvidiactl \
  --dev-bind /dev/null /dev/nvidia-modeset \
  --dev-bind /dev/null /dev/nvidia-uvm \
  --dev-bind /dev/null /dev/nvidia-uvm-tools \
  "$DIR/steamwebhelper.real" "$@"
CEFWRAP
          chmod +x "$WEBHELPER"
        fi
      '';
    };

    extraCompatPackages = with pkgs; [
      proton-ge-bin
      proton-cachyos
    ];
    remotePlay.openFirewall = true;
    localNetworkGameTransfers.openFirewall = true;
    dedicatedServer.openFirewall = true;

    # CJK fonts inside the Steam Linux runtime sandbox
    fontPackages = with pkgs; [
      wqy_zenhei
      noto-fonts-cjk-sans
    ];
  };
}
