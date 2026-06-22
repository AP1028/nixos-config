{pkgs, ...}: {
  environment.systemPackages = with pkgs; [onlyoffice-desktopeditors];

  # OnlyOffice can't read fonts from the Nix store — copy CJK fonts into the
  # user's home directory on every system activation.
  system.userActivationScripts = {
    flattenOnlyOfficeFonts = {
      text = ''
        # Ensure the folder exists if it doesn't already
        mkdir -p ~/.local/share/fonts

        # Wipe old copies so they stay fresh with system updates
        rm -f ~/.local/share/fonts/NotoSansCJK*

        # Cleanly dereference (-L) and copy the font out of the immutable Nix store
        cp -rL ${pkgs.noto-fonts-cjk-sans}/share/fonts/* ~/.local/share/fonts/

        # Force OnlyOffice to regenerate its font cache index on next launch
        rm -rf ~/.config/onlyoffice/DesktopEditors/FontCache
      '';
    };
  };
}
