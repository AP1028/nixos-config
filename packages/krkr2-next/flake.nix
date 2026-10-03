{
  description = "KrKr2-Next: Flutter-based KiriKiri2 emulator (unofficial packaging)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config.allowUnfree = true; # libunrar (RAR decompression)
        };
        engine = pkgs.callPackage ./engine.nix { };
      in
      {
        packages = {
          engine = engine;
          default = pkgs.callPackage ./app.nix {
            inherit engine;
            flutter347 = pkgs.flutter347;
          };
        };
        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            flutter347
            dart
          ];
        };
      }
    );
}
