{
  config,
  lib,
  pkgs,
  ...
}: let
  # NVIDIA vGPU *guest* driver (grid build) 16.14 / 535.309.01.
  # Built with nixpkgs' own nvidia packaging (nvidiaPackages.legacy_535)
  # but pointed at the grid .run instead of the regular driver:
  #   - kernel module + userspace: nixpkgs' battle-tested builder
  #     (soname symlinks, patchelf rpaths, GLVND/EGL/Vulkan wiring, kmod)
  #   - nvidia-gridd: not in nixpkgs' binary list, added via postInstall
  #   - license: gridd fetches a token from FastAPI-DLS (essential-vm)
  # Served from the Proxmox node (LAN mirror, /root/vgpu): the upstream alist
  # mirror keeps resetting HTTP/2 streams mid-transfer for this 332MB file.
  gridRunUrl = "https://alist.homelabproject.cc/d/foxipan/vGPU/16.14/NVIDIA-GRID-Linux-KVM-535.309.01-539.72/Guest_Drivers/NVIDIA-Linux-x86_64-535.309.01-grid.run";

  # Robust fetch: alist caps connections (~5min/~90MB per attempt, no matter
  # the connection dies and curl resumes with --continue-at -), so retry a lot,
  # force HTTP/1.1 (HTTP/2 stream resets), abort stalled connections fast, and
  # fall back to the alist proxy endpoint, then the LAN mirror on the Proxmox
  # node (vgpu-mirror.service). Same sha256 -> same store path regardless.
  gridRun = pkgs.fetchurl {
    urls = [
      gridRunUrl
      "https://alist.homelabproject.cc/p/foxipan/vGPU/16.14/NVIDIA-GRID-Linux-KVM-535.309.01-539.72/Guest_Drivers/NVIDIA-Linux-x86_64-535.309.01-grid.run"
      "http://192.168.3.100:8000/NVIDIA-Linux-x86_64-535.309.01-grid.run"
    ];
    sha256 = "1zym4ra7hahjrl86xx93rnhgka13pij600dqgi73p5g45mnrdym5";
    curlOptsList = [
      "--http1.1"
      "--retry" "10"
      "--retry-delay" "1"
      "--retry-all-errors"
      "--speed-limit" "10240"
      "--speed-time" "120"
    ];
  };

  nvidiaGrid = (config.boot.kernelPackages.nvidiaPackages.mkDriver {
    version = "535.309.01";
    url = gridRunUrl;
    sha256_64bit = "1zym4ra7hahjrl86xx93rnhgka13pij600dqgi73p5g45mnrdym5";
    useSettings = false;
    usePersistenced = false;
    useFabricmanager = false;
    postInstall = ''
      install -Dm755 nvidia-gridd $bin/bin/nvidia-gridd
      patchelf --set-rpath "$out/lib:$libPath" $bin/bin/nvidia-gridd
    '';
  }).overrideAttrs (old: {src = gridRun;});
in {
  imports = [./vgpu-guest-options.nix];

  # Explicit config block: assigning `config.local.*` above would trigger
  # NixOS' strict module mode for top-level `config`/`options` attributes.
  config = {
    nixpkgs.config.nvidia.acceptLicense = true;

    # The nixpkgs desktop nvidia driver must NOT be used (see gpu.nix):
    # it only activates via services.xserver.videoDrivers = ["nvidia"],
    # which is forced off here.
    services.xserver.videoDrivers = lib.mkForce [];

    # Kernel module for the running kernel, loaded at boot.
    # nouveau MUST not touch the vGPU: probing it first corrupts the MSI domain
    # (irq_domain_remove/msi_device_data_release warnings; nv_init_msi then
    # fails and the driver wedges -> nvidia-smi hangs in D state).
    boot.blacklistedKernelModules = ["nouveau"];
    boot.kernelModules = lib.mkAfter ["nvidia" "nvidia-uvm"];
    boot.extraModulePackages = [nvidiaGrid.mod];

    # Userspace libs (libnvidia-ml, libcuda, ...) for nvidia-smi and CUDA apps.
    environment.systemPackages = [nvidiaGrid.bin];

    # ld.so.conf.d/ldconfig is a dead end on NixOS: glibc's sysconfdir is
    # compiled to a store path, so ldconfig can't write a cache and the loader
    # never reads /etc/ld.so.cache. CUDA binaries instead get the grid lib dir
    # via rpath (see hosts/nixos-gpu-vm/packages/default.nix). The
    # local.nvidiaGridLib option is declared in vgpu-guest-options.nix.
    local.nvidiaGridLib = "${nvidiaGrid}/lib";

    # gridd.conf for the license client: FeatureType=1 = auto (Q profile -> vWS,
    # which FastAPI-DLS serves). FeatureType=4 (vGPU for Compute) is NOT served
    # by FastAPI-DLS v1.x and leaves the vGPU unlicensed.
    environment.etc."nvidia/gridd.conf".text = ''
      # Generated for FastAPI-DLS licensing
      FeatureType=1
    '';

    # nvidia-gridd fetches a client token from FastAPI-DLS on essential-vm
    # (192.168.3.151:443) and leases a license for the vGPU.
    systemd.services.nvidia-gridd = {
      description = "NVIDIA vGPU Guest daemon (license client)";
      wantedBy = ["multi-user.target"];
      after = ["nvidia-devnodes.service"];

      preStart = ''
        # gridd exits unless it can create its license state dir
        mkdir -p /var/lib/nvidia/GridLicensing
        TOKEN_DIR=/etc/nvidia/ClientConfigToken
        mkdir -p "$TOKEN_DIR"
        if ! ls "$TOKEN_DIR"/client_configuration_token_*.tok >/dev/null 2>&1; then
          ${pkgs.curl}/bin/curl -sk --max-time 20 \
            "https://192.168.3.151/-/client-token" \
            -o "$TOKEN_DIR/client_configuration_token_$(date +%m-%d-%Y-%H-%M-%S).tok" \
            || echo "warning: failed to fetch license token from FastAPI-DLS"
        fi
      '';

      serviceConfig = {
        # gridd daemonizes itself: with Type=simple systemd would see the
        # parent exit and report the unit dead (while the daemon keeps
        # running and holding the lease).
        Type = "forking";
        PIDFile = "/run/nvidia-gridd/nvidia-gridd.pid";
        ExecStart = "${nvidiaGrid.bin}/bin/nvidia-gridd";
        Restart = "on-failure";
        RestartSec = "5s";
      };
    };

    # The proprietary driver registers its char devices without devtmpfs
    # nodes; CUDA (cuInit) requires /dev/nvidia-uvm. Stock distros get these
    # from NVIDIA's udev mknod rules, which NixOS doesn't ship -> create the
    # nodes at boot (majors are dynamic, read from /proc/devices).
    systemd.services.nvidia-devnodes = {
      description = "Create NVIDIA vGPU device nodes";
      wantedBy = ["multi-user.target"];
      before = ["nvidia-gridd.service"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = pkgs.writeShellScript "nvidia-devnodes" ''
          AWK=${pkgs.gawk}/bin/awk
          MKNOD=${pkgs.coreutils}/bin/mknod
          MODPROBE=${pkgs.kmod}/bin/modprobe
          # nvidia_uvm loads on demand (first nvidia-smi/CUDA call) - make
          # sure it is present so its major shows up in /proc/devices.
          $MODPROBE nvidia_uvm 2>/dev/null || true
          for i in $(seq 1 20); do
            UVM_MAJ=$($AWK '$2 == "nvidia-uvm" {print $1}' /proc/devices)
            [ -n "$UVM_MAJ" ] && break
            sleep 1
          done
          NV_MAJ=$($AWK '$2 == "nvidia-frontend" {print $1}' /proc/devices)
          MODESET_MAJ=$($AWK '$2 == "nvidia-modeset" {print $1}' /proc/devices)
          [ -n "$NV_MAJ" ] && $MKNOD -m 666 /dev/nvidiactl c "$NV_MAJ" 255 2>/dev/null || true
          [ -n "$UVM_MAJ" ] && $MKNOD -m 666 /dev/nvidia-uvm c "$UVM_MAJ" 0 2>/dev/null || true
          [ -n "$MODESET_MAJ" ] && $MKNOD -m 666 /dev/nvidia-modeset c "$MODESET_MAJ" 0 2>/dev/null || true
          for minor in $($AWK '/Minor/{print $4}' /proc/driver/nvidia/gpus/*/information 2>/dev/null); do
            [ -n "$NV_MAJ" ] && $MKNOD -m 666 "/dev/nvidia$minor" c "$NV_MAJ" "$minor" 2>/dev/null || true
          done
          [ -e /dev/nvidia-uvm ] && [ -e /dev/nvidiactl ] || exit 1
        '';
      };
    };
  };
}
