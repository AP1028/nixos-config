{
  pkgs,
  lib,
  inputs,
  ...
}: let
  # Every ArtCraft app pinned to its newest upstream release, built with
  # nix-craftapps' own builder. This exists because nix-craftapps' daily
  # apps.json updater has failed every day since 2026-10-10, leaving the flake
  # stuck on its 2026-10-09 versions (e.g. wordcraft 0.3.0, whose font
  # dropdown deadlocks with a large font tree -- upstream #5/#59/#77).
  #
  # `hash` is the SRI hash of the official
  # <app>-<version>-linux-x86_64.tar.gz release asset. Bump with:
  #   nix store prefetch-file --json \
  #     https://github.com/storytold/<app>/releases/download/v<ver>/<app>-<ver>-linux-x86_64.tar.gz
  # Once apps.json catches up again, delete this file and its import.
  pins = {
    cadcraft.version = "0.6.2";
    cadcraft.hash = "sha256-Sj7HxTUOchK9tPc1r2xs8xnuF3wRUp7FR8d8kmQq1J0=";
    deckcraft.version = "0.6.1";
    deckcraft.hash = "sha256-EhXmTxGqaFKb4+/iB49Rw5p2ad4dY8zhtVisEZPxdWk=";
    designcraft.version = "0.7.1";
    designcraft.hash = "sha256-BaKyUx9vJnRrSnQwgf0A+ep3gi+heGY4AqDq7O1sFDc=";
    effectcraft.version = "0.9.2";
    effectcraft.hash = "sha256-kW0119wP1WULV/V25lViVtBd7fk+g6l0DBiSMZu0rBw=";
    filmcraft.version = "0.7.2";
    filmcraft.hash = "sha256-QXHEv19X/SlHVlX4pt9HGf7ajI8+2VskddjcESrTvoY=";
    gridcraft.version = "0.6.1";
    gridcraft.hash = "sha256-YRY7Ytn6+BS4ZOGyVdFdwxCnGnLKA9h5H6gCRCAWJ0U=";
    lightcraft.version = "0.7.1";
    lightcraft.hash = "sha256-hCiB9a0WUC3xHu70wo5dzyxdZrfU2DivcXmj/S4MtsA=";
    pdfcraft.version = "0.7.1";
    pdfcraft.hash = "sha256-vH1lFREnNyD2pcy+DdWyxN3MtsV2oK/2GfOdLFZnoxU=";
    photocraft.version = "0.8.2";
    photocraft.hash = "sha256-FsMImXbu4tKQ2+c5httINcHsWgQ8XBawF7JISP9eqCc=";
    soundcraft.version = "0.6.1";
    soundcraft.hash = "sha256-87+jc1FG5NexLNg2O4/ne77/Me6VOSKVAz9QsZFu/O4=";
    vectorcraft.version = "0.10.0";
    vectorcraft.hash = "sha256-pVc1oZKHcDjJtMMGlQT3pzoFQzpI7d3Y6U/H0plapvw=";
    wordcraft.version = "0.6.1";
    wordcraft.hash = "sha256-eb1UyBJ29upVEiJDKt7BXg6qtMtYgd7O446v16XKOPk=";
  };

  # Static metadata (title, description, repo) from the flake's app list.
  meta = builtins.fromJSON (builtins.readFile (inputs.nix-craftapps + "/apps.json"));
  buildApp = pkgs.callPackage (inputs.nix-craftapps + "/package.nix");
in {
  programs.craftapps = {
    enable = true;
    enableAll = true;
    # `linkFonts` (default) wires /usr/share/fonts, which the apps' text
    # tools require instead of fontconfig.

    apps = lib.mapAttrs (name: pin: {
      package = buildApp {
        name = name;
        info = meta.${name} // {
          inherit (pin) version;
          tag = "v${pin.version}";
          sources."x86_64-linux" = {
            url = "https://github.com/${meta.${name}.repo}/releases/download/v${pin.version}/${name}-${pin.version}-linux-x86_64.tar.gz";
            inherit (pin) hash;
          };
        };
      };
    }) pins;
  };
}
