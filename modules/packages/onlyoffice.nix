{pkgs, ...}: {
  environment.systemPackages = with pkgs; [onlyoffice-desktopeditors];

  # OnlyOffice can't read fonts from the Nix store — copy CJK fonts into the
  # user's home directory on every system activation.
  # system.userActivationScripts = {
  #   flattenOnlyOfficeFonts = {
  #     text = ''
  #       # Ensure the folder exists if it doesn't already
  #       mkdir -p ~/.local/share/fonts

  #       # Wipe old copies so they stay fresh with system updates
  #       rm -f ~/.local/share/fonts/NotoSansCJK*

  #       # Cleanly dereference (-L) and copy the font out of the immutable Nix store
  #       cp -rL ${pkgs.noto-fonts-cjk-sans}/share/fonts/* ~/.local/share/fonts/

  #       # Force OnlyOffice to regenerate its font cache index on next launch
  #       rm -rf ~/.config/onlyoffice/DesktopEditors/FontCache
  #     '';
  #   };
  # };
  system.userActivationScripts = {
    flattenOnlyOfficeFonts = {
      text = ''
        FONT_DIR="$HOME/.local/share/fonts"
        mkdir -p "$FONT_DIR"

        # Wipe old copies so they stay fresh with system updates
        chmod -R u+w "$FONT_DIR" 2>/dev/null || true
        rm -rf "$FONT_DIR"/*

        # Dynamically loop through every font available in the Nix system profile
        # and copy its contents cleanly (-L dereferences the Nix store symlinks)
        if [ -d "/run/current-system/sw/share/X11/fonts" ]; then
          cp -rL /run/current-system/sw/share/X11/fonts/* "$FONT_DIR/"
        fi

        # Also grab fonts from user-profile specific environments just in case
        if [ -d "$HOME/.nix-profile/share/fonts" ]; then
          cp -rL $HOME/.nix-profile/share/fonts/* "$FONT_DIR/"
        fi

        # Force OnlyOffice to regenerate its font cache index on next launch
        rm -rf "$HOME/.config/onlyoffice/DesktopEditors/FontCache"
      '';
    };
  };
}
