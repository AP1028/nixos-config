{
  lib,
  runCommand,
  erofs-utils,
  pkgsCross,
}:

# Dedicated x86_64 FEX rootfs for the steam-arm64 muvm VM.
#
# This is deliberately a SEPARATE derivation from cadence-env's
# fex-cadence-rootfs (modules/env/cadence-env.nix): the two VMs have
# different library needs and update independently, and sharing one image
# would mean a Cadence-side tweak could break Steam (or vice versa). Keep
# both copies.
#
# Why it is needed: Valve's fex-compat-tool
# (steamapps/common/FEX-Emu/fex-compat-tool) hardcodes an OS-provided rootfs
# path, /usr/share/guestos/fex-mesa (a SteamOS guest-image convention), and
# FEX refuses to run any x86_64 code without a rootfs. The steam-arm64
# launcher mounts this image into the muvm guest (muvm -f, merged rootfs)
# and symlinks the expected path to the mountpoint, so the tool finds a
# valid rootfs without patching Valve's script.
#
# Lean by design: GL/EGL/Vulkan/DRM/Wayland/ALSA on the x86 side are served
# by FEX thunks (steamapps/common/FEX-Emu/usr/share/fex-emu/GuestThunks),
# which forward to the arm64 host libraries in the steam-fhs env, and Proton
# ships its own x86_64 runtime alongside wine. The rootfs only carries the
# glibc base FEX bootstraps x86 ELFs against plus common low-level libs.
# Extend after ldd'ing a game that fails to start; x86 mesa/vulkan-loader
# are intentionally absent while the thunk path works.
let
  x86 = pkgsCross.gnu64;

  x86LibPkgs = [
    x86.glibc
    x86.gcc-unwrapped.lib
    x86.zlib
    x86.zstd
    x86.xz
    x86.bzip2
    x86.expat
    x86.ncurses
    x86.libffi
    x86.openssl
    x86.alsa-lib
    x86.dbus
  ];
in
runCommand "steam-arm64-fex-rootfs" {
  nativeBuildInputs = [erofs-utils];
} ''
  mkdir -p rootfs/lib64 rootfs/usr/lib64
  ln -sf ${x86.glibc}/lib/ld-linux-x86-64.so.2 rootfs/lib64/ld-linux-x86-64.so.2

  for p in ${lib.concatMapStringsSep " " (p: "${lib.getLib p}") x86LibPkgs}; do
    if [ -d "$p/lib" ]; then
      for f in "$p"/lib/*; do
        [ -e "$f" ] || continue
        case "$f" in
          *.a|*.la|*.o|*gconv*) continue ;;
        esac
        ln -sf "$f" rootfs/usr/lib64/
      done
    fi
  done

  mkfs.erofs $out rootfs/
''
