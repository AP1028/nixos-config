{...}: {
  programs.zsh = {
    enable = true;
    autosuggestions.enable = true;
    syntaxHighlighting.enable = true;
    ohMyZsh = {
      enable = true;
      plugins = ["history" "git" "sudo"];
      # Prompt is handled by starship; disable oh-my-zsh theming.
      theme = "";
    };
    interactiveShellInit = ''
      export PATH="$HOME/.local/bin:$PATH"
      fastfetch
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
