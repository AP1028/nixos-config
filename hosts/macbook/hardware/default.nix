{
  config,
  lib,
  pkgs,
  ...
}: {
  nix.settings.substituters = [
    "https://nixos-apple-silicon.cachix.org"
  ];
  nix.settings.trusted-public-keys = [
    "nixos-apple-silicon.cachix.org-1:8psDu5SA5dAD7qA0zMy5UT292TxeEPzIz8VVEr2Js20="
  ];

  hardware.asahi.enable = true;
  hardware.asahi.peripheralFirmwareDirectory = /. + "${config.local.configDir}/hosts/macbook/firmware";
  hardware.asahi.avd.vaapi-support = true;

  hardware.bluetooth.enable = true;
  hardware.bluetooth.powerOnBoot = true;

  # The stock Asahi config is built without the DMA-BUF heaps framework
  # (CONFIG_DMABUF_HEAPS is off), so /dev/dma_heap does not exist.  Waydroid's
  # init then logs "DMA-BUF system heap does not exist" and Android's
  # libdmabufheap logs "No ion heap of name system exists"; only DMA-BUF /
  # zero-copy (video) paths care, but this gives both the host and the Android
  # container a /dev/dma_heap/system.  Enabling this rebuilds linux-asahi and
  # needs a reboot.  See docs/waydroid-asahi.md.
  boot.kernelPatches = [
    {
      name = "dmabuf-heaps";
      patch = null;
      structuredExtraConfig = with lib.kernel; {
        DMABUF_HEAPS = yes;
        DMABUF_HEAPS_SYSTEM = yes;
      };
    }
  ];

  boot.loader.systemd-boot.enable = true;
  boot.loader.systemd-boot.configurationLimit = lib.mkForce 10;
  boot.loader.efi.canTouchEfiVariables = false;
  boot.loader.efi.efiSysMountPoint = "/efi";
}
