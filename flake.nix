{
  description = "Unified NixOS configuration for all machines";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    lanzaboote = {
      url = "github:nix-community/lanzaboote";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    i915-sriov-dkms = {
      url = "github:strongtz/i915-sriov-dkms/master";
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
      inputs.nixpkgs.follows = "nixpkgs";
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

    nix-proton-cachyos.url = "github:kimjongbing/nix-proton-cachyos";
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
        system = "x86_64-linux";
        specialArgs = {inherit inputs;};
        modules = [
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
        ];
      };

      nixos-service-vm = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = {inherit inputs;};
        modules = [
          ./hosts/nixos-service-vm/hardware-configuration.nix
          ./hosts/nixos-service-vm/default.nix

          vscode-server.nixosModules.default
        ];
      };

      nixos-git-vm = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = {inherit inputs;};
        modules = [
          ./hosts/nixos-git-vm/hardware-configuration.nix
          ./hosts/nixos-git-vm/default.nix

          vscode-server.nixosModules.default
        ];
      };

      macbook = nixpkgs.lib.nixosSystem {
        system = "aarch64-linux";
        specialArgs = {inherit inputs;};
        modules = [
          ./hosts/macbook/hardware-configuration.nix
          ./hosts/macbook/default.nix

          apple-silicon.nixosModules.default
        ];
      };
    };
  };
}
