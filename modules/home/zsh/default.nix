{...}: {
  # Full interactive zsh config, managed entirely by home-manager so it lands
  # in ~/.zshrc (and ~/.zshenv). This makes it inheritable by tools that read
  # the user's dotfiles directly, e.g. distrobox containers, unlike a
  # system-wide /etc/zshrc.
  programs.zsh = {
    enable = true;
    autosuggestion.enable = true;
    syntaxHighlighting.enable = true;
    oh-my-zsh = {
      enable = true;
      plugins = ["history" "git" "sudo"];
      # Prompt is handled by starship; disable oh-my-zsh theming.
      theme = "";
      # Inside rootless distrobox containers the read-only nix store maps to
      # owner "nobody", which oh-my-zsh's compaudit flags as insecure. The
      # store is immutable so it can't be re-owned; skip the check instead.
      # (No-op on the host, where the store is owned by root.)
      extraConfig = ''
        ZSH_DISABLE_COMPFIX=true
      '';
    };
    initContent = ''
      export PATH="$HOME/.local/bin:$PATH"
      # fastfetch may be absent inside containers; don't error if so.
      command -v fastfetch >/dev/null 2>&1 && fastfetch
    '';
  };

  programs.starship = {
    enable = true;
    # Plain-symbol style, no Nerd Fonts required.
    presets = ["no-nerd-font"];
    settings = {
      # FHS badge first, then the default starship prompt.
      format = "\${custom.fhs}$all";

      # Ported from the old bira prompt trick: show which FHS env we are in.
      custom.fhs = {
        command = "printf '(fhs:%s)' \"\${IN_FHS_ENV:-anonymous}\"";
        when = "[ -n \"$IN_FHS_ENV\" ] || [ -d /usr/lib ]";
        format = "[$output]($style) ";
        style = "bold purple";
        shell = ["/bin/sh"];
      };

      # no-nerd-font preset doesn't cover git_branch; drop its Nerd glyph.
      git_branch.symbol = "";

      # Always show user/host, using starship's native styling.
      username.show_always = true;
      hostname.ssh_only = false;
    };
  };
}
