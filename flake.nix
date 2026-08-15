{
  description = "Unified NixOS configuration for all machines";

  nixConfig = {
    extra-substituters = ["https://nixos-apple-silicon.cachix.org"];
    extra-trusted-public-keys = ["nixos-apple-silicon.cachix.org-1:8psDu5SA5dAD7qA0zMy5UT292TxeEPzIz8VVEr2Js20="];
  };

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # Stable track for the VM fleet: infrastructure wants stability, not
    # rolling churn. Eval-verified against all VM configs (2026-08).
    nixpkgs-stable.url = "github:NixOS/nixpkgs/nixos-26.05";

    lanzaboote = {
      url = "github:nix-community/lanzaboote";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    i915-sriov-dkms = {
      url = "github:strongtz/i915-sriov-dkms";
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

    # Home Manager matching the stable track: the VM fleet builds from
    # nixpkgs-stable (26.05), so its home-manager must be release-26.05
    # (mismatch check would otherwise fire).
    home-manager-stable = {
      url = "github:nix-community/home-manager/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs-stable";
    };

    nixvirt = {
      url = "github:AshleyYakeley/NixVirt";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nix-gaming-edge = {
      url = "github:powerofthe69/nix-gaming-edge";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # ComfyUI flake with NixOS service module + bundled comfy-kitchen
    # (NVFP4 / int8 ConvRot kernels) and pre-built PyTorch CUDA wheels.
    # Deliberately does NOT follow our nixpkgs: upstream's own pinned nixpkgs
    # matches the prebuilt store paths they publish to comfyui.cachix.org,
    # so we download instead of building (and their test suites pass there).
    comfyui-nix = {
      url = "github:utensils/comfyui-nix";
    };
  };

  outputs = inputs @ {
    self,
    nixpkgs,
    nixpkgs-stable,
    lanzaboote,
    i915-sriov-dkms,
    vscode-server,
    nix-flatpak,
    apple-silicon,
    home-manager,
    home-manager-stable,
    nixvirt,
    comfyui-nix,
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

          ./modules/packages/winapps.nix

          home-manager.nixosModules.home-manager
          nixvirt.nixosModules.default

          # Disable ceph in qemu_full (fails to build on unstable, not needed)
          ({ ... }: {
            nixpkgs.overlays = [
              (final: prev: {
                qemu_full = prev.qemu_full.override { cephSupport = false; };
                # moonlight-qt 6.1.0 does not build against ffmpeg >= 8
                # (AVCodec.pix_fmts was removed in FFmpeg 8.0); pin ffmpeg_7.
                moonlight-qt = prev.moonlight-qt.override { ffmpeg = prev.ffmpeg_7; };
              })
            ];
          })
        ];
      };

      nixos-service-vm = nixpkgs-stable.lib.nixosSystem {
        specialArgs = {inherit inputs;};
        modules = [
          { nixpkgs.hostPlatform = "x86_64-linux"; }
          home-manager-stable.nixosModules.home-manager
          ./hosts/nixos-service-vm/hardware-configuration.nix
          ./hosts/nixos-service-vm/default.nix

          vscode-server.nixosModules.default
        ];
      };

      nixos-git-vm = nixpkgs-stable.lib.nixosSystem {
        specialArgs = {inherit inputs;};
        modules = [
          { nixpkgs.hostPlatform = "x86_64-linux"; }
          home-manager-stable.nixosModules.home-manager
          ./hosts/nixos-git-vm/hardware-configuration.nix
          ./hosts/nixos-git-vm/default.nix

          vscode-server.nixosModules.default
        ];
      };

      nixos-gpu-vm = nixpkgs-stable.lib.nixosSystem {
        specialArgs = {inherit inputs;};
        modules = [
          { nixpkgs.hostPlatform = "x86_64-linux"; }
          home-manager-stable.nixosModules.home-manager
          ./hosts/nixos-gpu-vm/hardware-configuration.nix
          ./hosts/nixos-gpu-vm/default.nix

          vscode-server.nixosModules.default
        ];
      };

      nixos-gpu-host = nixpkgs-stable.lib.nixosSystem {
        specialArgs = {inherit inputs;};
        modules = [
          { nixpkgs.hostPlatform = "x86_64-linux"; }
          home-manager-stable.nixosModules.home-manager
          ./hosts/nixos-gpu-host/hardware-configuration.nix
          ./hosts/nixos-gpu-host/default.nix

          vscode-server.nixosModules.default
        ];
      };

      nixos-webapp-vm = nixpkgs-stable.lib.nixosSystem {
        specialArgs = {inherit inputs;};
        modules = [
          { nixpkgs.hostPlatform = "x86_64-linux"; }
          home-manager-stable.nixosModules.home-manager
          ./hosts/nixos-webapp-vm/hardware-configuration.nix
          ./hosts/nixos-webapp-vm/default.nix
        ];
      };

      nixos-essential-vm = nixpkgs-stable.lib.nixosSystem {
        specialArgs = {inherit inputs;};
        modules = [
          { nixpkgs.hostPlatform = "x86_64-linux"; }
          home-manager-stable.nixosModules.home-manager
          ./hosts/nixos-essential-vm/hardware-configuration.nix
          ./hosts/nixos-essential-vm/default.nix
        ];
      };

      # Draft: hardware-configuration.nix intentionally omitted; it will be
      # generated on the VM ("nixos-generate-config") and added here once the
      # VM is set up with the HDD pool attached.
      nixos-file-vm = nixpkgs-stable.lib.nixosSystem {
        specialArgs = {inherit inputs;};
        modules = [
          { nixpkgs.hostPlatform = "x86_64-linux"; }
          home-manager-stable.nixosModules.home-manager
          ./hosts/nixos-file-vm/default.nix

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
