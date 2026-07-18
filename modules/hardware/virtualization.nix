{
  config,
  lib,
  pkgs,
  ...
}: {
  # ── VFIO / GPU passthrough ──────────────────────────────────────

  boot.kernelModules = [
    "vfio_pci"
    "vfio"
    "vfio_iommu_type1"
    "br_netfilter"
  ];
  # ── libvirt + QEMU ─────────────────────────────────────────────

  system.activationScripts.ssdt-battery.text = ''
    cp ${../../vms/ssdt-battery.aml} /var/lib/libvirt/vbios/ssdt-battery.aml
    chmod 644 /var/lib/libvirt/vbios/ssdt-battery.aml
  '';

  virtualisation.libvirtd = {
    enable = true;
    qemu = {
      package = pkgs.qemu_full;
      swtpm.enable = true;
      verbatimConfig = ''
        namespaces = []
        cgroup_device_acl = [
          "/dev/null", "/dev/full", "/dev/zero",
          "/dev/random", "/dev/urandom",
          "/dev/ptmx", "/dev/kvm", "/dev/kqemu",
          "/dev/rtc","/dev/hpet", "/dev/vfio/vfio",
          "/dev/kvmfr0"
        ]
      '';
    };
  };

  virtualisation.libvirt = {
    enable = true;
    connections."qemu:///system" = {
      domains = [
        {
          definition = ../../vms/win11-igpu.xml;
          active = false;
        }
        {
          definition = ../../vms/win11-igpu-nvme.xml;
          active = false;
        }
        {
          definition = ../../vms/win11-stealthy.xml;
          active = false;
        }
        {
          definition = ../../vms/win11-stealthy-dgpu.xml;
          active = false;
        }
        {
          definition = ../../vms/win11-stealthy-dgpu-nvme.xml;
          active = false;
        }
        {
          definition = ../../vms/win11-stealthy-dgpu-v2.xml;
          active = false;
        }
        {
          definition = ../../vms/win11-igpu-v2.xml;
          active = false;
        }
        {
          definition = ../../vms/win11-igpu-nvme-v2.xml;
          active = false;
        }
        {
          definition = ../../vms/win11-stealthy-v2.xml;
          active = false;
        }
        {
          definition = ../../vms/win11-stealthy-dgpu-nvme-v2.xml;
          active = false;
        }
        {
          definition = ../../vms/win11-virtio-v2.xml;
          active = false;
        }
        {
          definition = ../../vms/win11-virtio-dgpu-v2.xml;
          active = false;
        }
        {
          definition = ../../vms/win11-virtio-dgpu-nvme-v2.xml;
          active = false;
        }
        {
          definition = ../../vms/win11-virtio.xml;
          active = false;
        }
        {
          definition = ../../vms/win11-virtio-dgpu.xml;
          active = false;
        }
        {
          definition = ../../vms/win11-virtio-dgpu-nvme.xml;
          active = false;
        }
      ];
      networks = [
        {
          definition = ../../vms/network-default.xml;
          active = true;
        }
      ];
      pools = [
        {
          definition = ../../vms/pool-default.xml;
          active = true;
        }
        {
          definition = ../../vms/pool-Desktop.xml;
          active = true;
        }
        {
          definition = ../../vms/pool-Downloads.xml;
          active = true;
        }
        {
          definition = ../../vms/pool-nvram.xml;
          active = true;
        }
      ];
    };
  };

  # Podman with Docker-compatible CLI (for distrobox)
  virtualisation.podman = {
    enable = true;
    dockerCompat = true;
  };

  # ── KVMFR (Looking Glass shared memory) ─────────────────────────

  boot.extraModulePackages = with config.boot.kernelPackages; [kvmfr];

  # Intel IOMMU, VFIO, and KVMFR configuration
  boot.kernelParams = [
    "intel_iommu=on" # required for VFIO
    "iommu=pt" # passthrough mode, skips identity mapping for the host
    "kvmfr.static_size_mb=128" # shared memory window for Looking Glass
    # "vfio_pci.disable_idle_d3=1" # prevent GPU reset issues on passthrough
    "kvm.ignore_msrs=1"
    "kvm.report_ignored_msrs=0"
    # "vfio-pci.ids=10de:2c59,10de:22e9" # NVIDIA GPU + audio — uncomment to bind at boot
  ];

  boot.initrd.kernelModules = ["kvmfr"];

  # udev rule: allow kvm group access to Looking Glass shared memory
  services.udev.packages = lib.singleton (
    pkgs.writeTextFile {
      name = "kvmfr";
      text = ''
        SUBSYSTEM=="kvmfr", GROUP="kvm", MODE="0660", TAG+="uaccess"
      '';
      destination = "/etc/udev/rules.d/70-kvmfr.rules";
    }
  );

  programs.virt-manager.enable = true;

  # Remove memory locking limits for VM users (GPU passthrough needs large locked pages)
  security.pam.loginLimits = [
    {
      domain = "@kvm";
      type = "-";
      item = "memlock";
      value = "unlimited";
    }
    {
      domain = "@libvirtd";
      type = "-";
      item = "memlock";
      value = "unlimited";
    }
    {
      domain = "@qemu-libvirtd";
      type = "-";
      item = "memlock";
      value = "unlimited";
    }
    {
      domain = config.local.username;
      type = "-";
      item = "memlock";
      value = "unlimited";
    }
  ];

  boot.extraModprobeConfig = "options kvm_intel nested=1";

  # ── NVMe / GPU hot‑swap between host and VM ────────────────────

  environment.systemPackages = with pkgs; [
    looking-glass-client
  ];

  virtualisation.spiceUSBRedirection.enable = true;

  # # ── Libvirt hook: auto-run gpu-to-vfio / gpu-to-host on VM start/stop ──
  # # NixOS compiles libvirt with SYSCONFDIR=/var/lib, so hooks must be placed
  # # under /var/lib/libvirt/hooks/ (NOT /etc/libvirt/hooks/).
  # #
  # # NixOS deploys individual hooks into qemu.d/ but does NOT generate the
  # # main dispatcher script that libvirt expects at …/hooks/qemu.
  # # We create the dispatcher ourselves via a oneshot service that must run
  # # before libvirtd starts.
  # virtualisation.libvirtd.hooks.qemu = {
  #   "Windows 11 VM - VirtIO dGPU with Drive" = "${pkgs.writeShellScript "libvirt-qemu-gpu-hook" ''
  #     set -euo pipefail

  #     PATH="/run/current-system/sw/bin:$PATH"

  #     GPU_TO_VFIO="${gpuVfioScripts.gpu-to-vfio}/bin/gpu-to-vfio"
  #     GPU_TO_HOST="${gpuVfioScripts.gpu-to-host}/bin/gpu-to-host"

  #     VM="$1" ACTION="$2" PHASE="$3"

  #     if [ "$ACTION" = "start" ] && [ "$PHASE" = "begin" ]; then
  #       CMD="$GPU_TO_VFIO"
  #       MSG="GPU not ready for passthrough — run gpu-to-vfio manually"
  #     elif [ "$ACTION" = "stopped" ] && [ "$PHASE" = "end" ]; then
  #       CMD="$GPU_TO_HOST"
  #       MSG="GPU not ready to return to host — run gpu-to-host manually"
  #     else
  #       exit 0
  #     fi

  #     # Skip if this VM doesn't use the NVIDIA GPU.
  #     # libvirt passes the domain XML on stdin — read it with a timeout to
  #     # avoid hanging if stdin is empty/closed.
  #     XML="$([ -t 0 ] && echo "" || cat)"
  #     if [ -n "$XML" ]; then
  #       if ! echo "$XML" | grep -qE "vendor.*0x10de" &&
  #          ! echo "$XML" | grep -qE "bus='0x01'[^>]*slot='0x00'" &&
  #          ! echo "$XML" | grep -qE '<address[^>]*bus="0x01"[^>]*slot="0x00"'; then
  #         exit 0
  #       fi
  #     fi

  #     if ! "$CMD" -s; then
  #       echo "HOOK [$VM]: $MSG" >&2
  #       exit 1
  #     fi
  #   ''}";
  # };

  # # Generate the wrapper script that libvirt actually invokes.
  # # Without this, libvirt looks for /var/lib/libvirt/hooks/qemu (the
  # # dispatcher) and never reaches anything inside qemu.d/.
  # system.activationScripts.libvirtd-hook-dispatcher = let
  #   hookWrapper = pkgs.writeShellScript "libvirt-hook-dispatcher" ''
  #     DIR="/var/lib/libvirt/hooks/$1.d"
  #     if [ ! -d "$DIR" ]; then
  #       exit 0
  #     fi
  #     # Save stdin (domain XML) to pass to each sub‑hook.
  #     # libvirt always provides stdin; but if fd 0 is a tty we skip.
  #     if [ -t 0 ]; then
  #       INPUT=""
  #     else
  #       INPUT="$(cat)"
  #     fi
  #     shopt -s nullglob
  #     FAILED=0
  #     for hook in "$DIR"/*; do
  #       if [ -x "$hook" ]; then
  #         printf '%s' "$INPUT" | "$hook" "$2" "$3" "$4" || FAILED=1
  #       fi
  #     done
  #     exit $FAILED
  #   '';
  # in ''
  #   mkdir -p /var/lib/libvirt/hooks
  #   install -m 0755 "${hookWrapper}" /var/lib/libvirt/hooks/qemu
  # '';
}
