{
  config,
  lib,
  pkgs,
  ...
}: {
  boot.initrd.systemd.services.vfio-override-nvme = {
    description = "Override NVMe driver with vfio-pci for 0000:02:00.0";
    after = ["systemd-modules-load.service"];
    wantedBy = ["initrd.target"];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };

    script = ''
      echo "vfio-pci" > /sys/bus/pci/devices/0000:02:00.0/driver_override
      echo "0000:02:00.0" > /sys/bus/pci/drivers/nvme/unbind 2>/dev/null || true
      echo "0000:02:00.0" > /sys/bus/pci/drivers_probe
    '';
  };
}
