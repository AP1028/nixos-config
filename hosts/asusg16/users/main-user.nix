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
    "uinput"
    "video"
    "input"
  ];

  # Passwordless sudo for the wheel group on this host.
  #
  # This machine is driven over SSH for hackintosh work (EFI/OC kext swaps, ESP
  # repairs, reboots). Each fresh boot otherwise leaves sudo prompting for a
  # password over a non-interactive channel, which blocks unattended work until
  # a human intervenes.
  #
  # Trade-off: anyone holding the account SSH key gets root here. Accepted
  # deliberately for this workstation.
  security.sudo.wheelNeedsPassword = false;

  users.groups.qemu-libvirtd = {};

  users.users.qemu-libvirtd = {
    isSystemUser = true;
    group = "qemu-libvirtd";
    extraGroups = ["kvm"];
  };
}
