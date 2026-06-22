{...}: {
  programs.zsh = {
    enable = true;
    autosuggestions.enable = true;
    syntaxHighlighting.enable = true;
    ohMyZsh = {
      enable = true;
      plugins = ["history" "git" "sudo"];
      theme = "bira";
    };

    interactiveShellInit = ''
      if [[ -n "$IN_FHS_ENV" || -d /usr/lib ]]; then
        function fhs_prompt_info() {
          if [[ -n "$IN_FHS_ENV" ]]; then
            echo "%B%F{magenta}(fhs:$IN_FHS_ENV)%f%b "
          else
            echo "%B%F{magenta}(fhs:anonymous)%f%b "
          fi
        }
        function patch_bira_prompt() {
          if [[ "$PROMPT" != *"fhs_prompt_info"* ]]; then
            PROMPT="''${PROMPT//╭─/╭─\$(fhs_prompt_info)}"
          fi
        }
        setopt prompt_subst
        precmd_functions+=(patch_bira_prompt)
      fi
    '';
  };
}
