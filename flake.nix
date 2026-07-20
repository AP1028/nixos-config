{
  description = "Unified NixOS configuration for all machines";

  nixConfig = {
    extra-substituters = ["https://nixos-apple-silicon.cachix.org"];
    extra-trusted-public-keys = ["nixos-apple-silicon.cachix.org-1:8psDu5SA5dAD7qA0zMy5UT292TxeEPzIz8VVEr2Js20="];
  };

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    lanzaboote = {
      url = "github:nix-community/lanzaboote";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    i915-sriov-dkms = {
      url = "github:strongtz/i915-sriov-dkms/kernel-v7.1";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    winapps = {
      url = "github:winapps-org/winapps";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nixos-23-11.url = "github:nixos/nixpkgs/nixos-23.11";

    # Pinned to nixpkgs with clash-verge-rev 2.4.7 (2.5.1 has blank proxy regression)
    old-nixpkgs.url = "github:NixOS/nixpkgs/9ae611a455b90cf061d8f332b977e387bda8e1ca";

    vscode-server = {
      url = "github:nix-community/nixos-vscode-server";
    };

    nix-flatpak.url = "github:gmodena/nix-flatpak";

    apple-silicon.url = "github:nix-community/nixos-apple-silicon";

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nixvirt = {
      url = "github:AshleyYakeley/NixVirt";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nix-gaming-edge = {
      url = "github:powerofthe69/nix-gaming-edge";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Pinned to a commit before freecad build breakage on unstable (pdal/GDAL API)
    qemu-nixpkgs.url = "github:NixOS/nixpkgs/65179426c83bb3f6bc14898b42ea1c6f01d374b0";
  };

  outputs = inputs @ {
    self,
    nixpkgs,
    lanzaboote,
    i915-sriov-dkms,
    vscode-server,
    nix-flatpak,
    apple-silicon,
    home-manager,
    nixvirt,
    ...
  }: {
    nixosConfigurations = {
      asusg16 = nixpkgs.lib.nixosSystem {
        specialArgs = {inherit inputs;};
        modules = [
          { nixpkgs.hostPlatform = "x86_64-linux"; }
          ./hosts/asusg16/hardware-configuration.nix
          ./hosts/asusg16/default.nix

          lanzaboote.nixosModules.lanzaboote
          vscode-server.nixosModules.default
          i915-sriov-dkms.nixosModules.default
          nix-flatpak.nixosModules.nix-flatpak

          ./modules/hardware/supergfxctl-overlay.nix
          ./modules/packages/winapps.nix

          home-manager.nixosModules.home-manager
          nixvirt.nixosModules.default

          # Pin freecad from stable nixpkgs (pdal/GDAL API breakage on unstable)
          # Disable ceph in qemu_full (fails to build on unstable, not needed)
          ({ inputs, ... }: {
            nixpkgs.overlays = [
              (final: prev: {
                freecad = inputs.qemu-nixpkgs.legacyPackages.${final.system}.freecad;
                qemu_full = prev.qemu_full.override { cephSupport = false; };
              })
            ];
          })
        ];
      };

      nixos-service-vm = nixpkgs.lib.nixosSystem {
        specialArgs = {inherit inputs;};
        modules = [
          { nixpkgs.hostPlatform = "x86_64-linux"; }
          ./hosts/nixos-service-vm/hardware-configuration.nix
          ./hosts/nixos-service-vm/default.nix

          vscode-server.nixosModules.default
        ];
      };

      nixos-git-vm = nixpkgs.lib.nixosSystem {
        specialArgs = {inherit inputs;};
        modules = [
          { nixpkgs.hostPlatform = "x86_64-linux"; }
          ./hosts/nixos-git-vm/hardware-configuration.nix
          ./hosts/nixos-git-vm/default.nix

          vscode-server.nixosModules.default
        ];
      };

      macbook = nixpkgs.lib.nixosSystem {
        specialArgs = {inherit inputs;};
        modules = [
          { nixpkgs.hostPlatform = "aarch64-linux"; }
          ./hosts/macbook/hardware-configuration.nix
          ./hosts/macbook/default.nix

          apple-silicon.nixosModules.default
          home-manager.nixosModules.home-manager
        ];
      };
    };
  };
}
