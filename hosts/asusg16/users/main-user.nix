{
  config,
  lib,
  pkgs,
  ...
}: {
  imports = [
    ../../../modules/users/main-user.nix
  ];

  users.users.${config.local.username}.extraGroups = [
    "libvirtd"
    "kvm"
    "asusd"
    "supergfxd"
    "uinput"
    "video"
    "input"
  ];

  users.groups.qemu-libvirtd = {};

  users.users.qemu-libvirtd = {
    isSystemUser = true;
    group = "qemu-libvirtd";
    extraGroups = ["kvm"];
  };
}
