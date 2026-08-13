{
  config,
  lib,
  pkgs,
  ...
}: let
  # NVIDIA vGPU *guest* driver (grid build) 16.14 / 535.309.01.
  # The nixpkgs nvidia package is the desktop driver and cannot drive a vGPU
  # (no nvidia-gridd license client, no vGPU support in the module build).
  # So we build the grid driver from the official .run:
  #   - kernel module: nixpkgs-style build (same makeFlags as nixpkgs'
  #     nvidia_x11 kernel-modules.nix), wired into boot.extraModulePackages
  #   - userspace: extracted into a store path, exposed via ld.so.conf
  #   - nvidia-gridd: license client talking to FastAPI-DLS (essential-vm)
  gridRun = pkgs.fetchurl {
    url = "https://alist.homelabproject.cc/d/foxipan/vGPU/16.14/NVIDIA-GRID-Linux-KVM-535.309.01-539.72/Guest_Drivers/NVIDIA-Linux-x86_64-535.309.01-grid.run";
    sha256 = "1zym4ra7hahjrl86xx93rnhgka13pij600dqgi73p5g45mnrdym5";
  };

  # Extract the .run without executing it (payload = tar after the `skip=` line).
  grid = pkgs.stdenv.mkDerivation {
    pname = "nvidia-vgpu-guest";
    version = "535.309.01";
    src = gridRun;
    outputs = ["out" "modsrc"];
    nativeBuildInputs = [pkgs.libarchive pkgs.zstd];

    unpackPhase = ''
      skip=$(sed 's/^skip=//; t; d' $src)
      tail -n +$skip $src | bsdtar xvf -
      sourceRoot=.
    '';

    installPhase = ''
      mkdir -p $out/lib $out/bin
      cp -prd *.so.* $out/lib/ 2>/dev/null || true
      for b in nvidia-smi nvidia-debugdump nvidia-gridd nvidia-xconfig nvidia-bug-report.sh; do
        [ -e "$b" ] && cp -p "$b" $out/bin/ || true
      done
      [ -d usr ] && cp -prd usr/* $out/ || true
      cp -r kernel $modsrc
    '';
  };

  kernel = config.boot.kernelPackages.kernel;
in {
  # The nixpkgs desktop nvidia driver must NOT be used (see gpu.nix):
  # it only activates via services.xserver.videoDrivers = ["nvidia"],
  # which is forced off here.
  services.xserver.videoDrivers = lib.mkForce [];

  # Kernel module for the running kernel, loaded at boot.
  boot.kernelModules = lib.mkAfter ["nvidia"];
  boot.extraModulePackages = [
    (pkgs.stdenv.mkDerivation {
      pname = "nvidia-vgpu-guest-kmod";
      version = "535.309.01-${kernel.modDirVersion}";
      src = grid.modsrc;

      nativeBuildInputs = kernel.moduleBuildDependencies;

      makeFlags = config.boot.kernelPackages.kernelModuleMakeFlags
        ++ [
          "IGNORE_PREEMPT_RT_PRESENCE=1"
          "SYSSRC=${kernel.dev}/lib/modules/${kernel.modDirVersion}/source"
          "SYSOUT=${kernel.dev}/lib/modules/${kernel.modDirVersion}/build"
          "MODLIB=$(out)/lib/modules/${kernel.modDirVersion}"
          "DATE="
          "TARGET_ARCH=${pkgs.stdenv.hostPlatform.parsed.cpu.name}"
        ];

      buildTargets = ["modules"];
      installTargets = ["modules_install"];
      enableParallelBuilding = true;
    })
  ];

  # Userspace libs (libnvidia-ml, libcuda, ...) for nvidia-smi and CUDA apps.
  environment.etc."ld.so.conf.d/nvidia-grid.conf".text = "${grid}/lib";
  environment.systemPackages = [grid];

  # gridd.conf for the license client: FeatureType=4 = "NVIDIA vGPU for Compute"
  environment.etc."nvidia/gridd.conf".text = ''
    # Generated for FastAPI-DLS licensing (vGPU for Compute)
    FeatureType=4
  '';

  # nvidia-gridd fetches a client token from FastAPI-DLS on essential-vm
  # (192.168.3.151:443) and leases a license for the vGPU.
  systemd.services.nvidia-gridd = {
    description = "NVIDIA vGPU Guest daemon (license client)";
    wantedBy = ["multi-user.target"];
    unitConfig.ConditionPathExists = "/dev/nvidiactl";

    preStart = ''
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
      Type = "simple";
      ExecStart = "${grid}/bin/nvidia-gridd";
      Environment = "LD_LIBRARY_PATH=${grid}/lib";
      Restart = "on-failure";
      RestartSec = "5s";
    };
  };
}
