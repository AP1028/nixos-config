{
  lib,
  runCommand,
  erofs-utils,
  pkgsCross,
  pkgs,
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
# A "combined arch" install, matching Valve's guestos fex-mesa rootfs: the
# x86_64 half (below) is what the emulated side links against, and the arm64
# half is what the FEX *host* thunk libraries (HostThunks/*-host.so, arm64)
# dlopen. Both halves matter — the host thunks need real aarch64 libEGL/
# libGL/libvulkan plus mesa's asahi driver and Vulkan ICD findable at the
# conventional paths inside the game container, otherwise mesa reports
# "failed to load driver: asahi" and falls back to zink/llvmpipe.
let
  x86 = pkgsCross.gnu64;

  # Everything whose closure should end up in the rootfs's multiarch library
  # directories, for each architecture. Taken as a closure rather than a
  # hand-picked list: pressure-vessel treats the provider as a complete
  # userland, so every missing library surfaces later as an unrelated-looking
  # failure (libdrm for mesa's driver dlopen, libz for its own helpers, ...).
  graphicsRoots = p:
    [
      # The C library itself — without it the container-side arm64 helpers
      # (python3 etc.) die with "libc.so.6: cannot open shared object file"
      p.glibc
      # GL / EGL / Vulkan and the DRM stack
      p.mesa
      p.libglvnd
      p.vulkan-loader
      p.libdrm
      p.libgbm
      # X11 / Wayland surfaces mesa and Vulkan need
      p.libxcb
      p.libx11
      p.libxext
      p.libxfixes
      p.libxrandr
      p.libxi
      p.libxcursor
      p.libxrender
      p.libxtst
      p.libxshmfence
      p.libxau
      p.libxdmcp
      p.libsm
      p.libice
      p.libxkbcommon
      p.wayland
      # Support libraries (libgallium's NEEDED list plus common deps)
      p.libffi
      p.zlib
      p.bzip2
      p.xz
      p.zstd
      p.expat
      p.elfutils
      p.lm_sensors
      p.llvmPackages_21.llvm
      # The C++ runtime — FEX itself and mesa's drivers link libstdc++.
      p.stdenv.cc.cc.lib
      # Base userland: pressure-vessel runs helpers (python3, locale tools)
      # through the provider, and those need these.
      p.python3
      p.openssl
      p.ncurses
      p.readline
      p.sqlite
      p.dbus
      p.glib
      p.freetype
      p.fontconfig
      p.libpng
      p.systemd
      p.alsa-lib
      # Additional base libs the container runtime needs
      p.curl
      p.libssh2
      p.nghttp2
      p.e2fsprogs
    ];

  arm64Closure = pkgs.closureInfo {rootPaths = graphicsRoots pkgs;};
  x86Closure = pkgs.closureInfo {rootPaths = graphicsRoots x86;};

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
  outputs = [ "out" "ldso" ];
  nativeBuildInputs = [erofs-utils pkgs.python3];
  passthru.arm64Closure = arm64Closure;
  passthru.x86Closure = x86Closure;
} ''
  mkdir -p rootfs/lib64 rootfs/usr/lib64 rootfs/usr/bin
  ln -sf ${x86.glibc}/lib/ld-linux-x86-64.so.2 rootfs/lib64/ld-linux-x86-64.so.2

  # x86 shells/tools for FEX's script handling and PV's in-container checks.
  # The depot FEX resolves a script's shebang interpreter through the rootfs
  # and requires it to be an x86 ELF (an arm64 /bin/sh fails with "Invalid or
  # Unsupported elf file"), and PV's container self-check execs plain `true`
  # from PATH — the guest's own /usr/bin holds only `env`, so without a real
  # x86 userland here that check dies with "execvp true: No such file or
  # directory". The merged rootfs takes /usr from this erofs first, so these
  # shadow the guest's /usr/bin; /bin is shadowed by the guest-setup script
  # in steam-arm64.nix (muvm binds guest /bin there, which an erofs cannot
  # override). Valve's own guestos rootfs ships a full multiarch tree here.
  ln -sf ${x86.bash}/bin/bash rootfs/usr/bin/bash
  for t in ${x86.coreutils}/bin/*; do
    [ -e "$t" ] && ln -sf "$t" rootfs/usr/bin/
  done

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

  # ── x86 multiarch mirror for FEX's thunk overlays ─────────────────────
  # FEX substitutes @PREFIX_LIB@ in its ThunksDB.json with
  # /usr/lib/x86_64-linux-gnu/ (that string is compiled into the FEX binary) —
  # Valve's rootfs layout. It overlays the guest thunk stubs for libGL,
  # libEGL, libvulkan, libdrm and libasound at those paths so the emulated
  # side calls through to the arm64 host stack. Our x86 libraries live in
  # /usr/lib64, so no overlay ever matched and the emulated side loaded the
  # real x86 mesa instead, which cannot drive the Asahi GPU — the source of
  # "failed to load driver: asahi" and the zink fallback failing with
  # VK_ERROR_INCOMPATIBLE_DRIVER. Mirror the tree so the overlays apply.
  mkdir -p rootfs/usr/lib/x86_64-linux-gnu
  ln -sf /lib64/ld-linux-x86-64.so.2 rootfs/usr/lib/x86_64-linux-gnu/ld-linux-x86-64.so.2
  for f in rootfs/usr/lib64/*; do
    [ -e "$f" ] || continue
    ln -sf "/usr/lib64/''${f##*/}" rootfs/usr/lib/x86_64-linux-gnu/
  done

  # ── graphics stack for both architectures ─────────────────────────────
  # The whole closure, sorted into /usr/lib/<triple>/ by ELF e_machine. See
  # fex-rootfs-copy-closure.py for why this is closure-wide rather than a
  # hand-picked list, and why the entries must be real files inside the
  # provider prefix (capsule-capture refuses anything outside it).
  python3 ${./fex-rootfs-copy-closure.py} ${arm64Closure}/store-paths rootfs usr/lib
  python3 ${./fex-rootfs-copy-closure.py} ${x86Closure}/store-paths rootfs usr/lib

  # PV logs: 'We were expecting the drirc.d directory in the provider to be
  # located in "/usr/share/drirc.d"'. Give it one.
  mkdir -p rootfs/usr/share/drirc.d
  cp -a ${pkgs.mesa}/share/drirc.d/. rootfs/usr/share/drirc.d/ 2>/dev/null || true

  # ── glibc's userland tools, which pressure-vessel looks for in the provider
  # and without which it logs 'Cannot find ldconfig / ldd / locale /
  # localedef'. It uses them to (re)generate the container's loader cache and
  # locale data — and the container's own libz ships without its libz.so.1
  # soname link, so that regeneration is what makes dlopen("libz.so.1") work.
  # Without it PV's helper dies with
  #   /usr/bin/python3: error while loading shared libraries: libz.so.1
  # and the launch never reaches Proton. These must be the x86_64 build, since
  # /usr/bin in this rootfs is the emulated userland; glibc's gconv modules sit
  # alongside for charset conversion during locale generation.
  mkdir -p rootfs/usr/bin rootfs/usr/lib/x86_64-linux-gnu
  cp -a ${lib.getBin x86.glibc}/bin/. rootfs/usr/bin/ 2>/dev/null || true
  cp -a ${x86.glibc}/lib/gconv rootfs/usr/lib/x86_64-linux-gnu/ 2>/dev/null || true
  cp -a ${x86.glibc}/lib/locale rootfs/usr/lib/x86_64-linux-gnu/ 2>/dev/null || true

  # The graphics-provider spec requires the provider root to carry
  # "sbin/ldconfig" (pv-wrap looks there when it regenerates the container's
  # loader cache); /usr/bin alone is not enough.
  mkdir -p rootfs/sbin rootfs/usr/sbin
  for t in ldconfig ldd locale localedef; do
    [ -e ${lib.getBin x86.glibc}/bin/$t ] || continue
    ln -sf ${lib.getBin x86.glibc}/bin/$t rootfs/sbin/$t
    ln -sf ${lib.getBin x86.glibc}/bin/$t rootfs/usr/sbin/$t
  done

  # ── x86 base system libs for the container's multiarch search path ────
  # The PV container's x86 helper binaries (python3, etc.) resolve their
  # NEEDED libs from /usr/lib/x86_64-linux-gnu/ inside the container. This
  # dir is backed by the provider rootfs, so the base x86 libs must be here
  # as real files (the graphics closure only covers mesa/llvm/etc.). Copy
  # glibc, zlib, cc.lib (libstdc++/libgcc_s) and friends.
  echo "Copying x86 base libs into provider multiarch dir..." >&2
  for p in ${x86.glibc} ${x86.zlib} ${x86.stdenv.cc.cc.lib} ${x86.libgcc} ${x86.libxcrypt} ${x86.libffi}; do
    libdir="$p/lib"
    [ -d "$libdir" ] || continue
    for f in "$libdir"/*.so*; do
      [ -e "$f" ] || continue
      base=$(basename "$f")
      cp -aL --remove-destination "$f" "rootfs/usr/lib/x86_64-linux-gnu/$base" 2>/dev/null || true
    done
  done

  # Nix's cross-built libgcc_s.so.1 carries PT_GNU_STACK=RWE; the Asahi
  # guest kernel refuses executable stacks ("cannot enable executable stack
  # as shared object requires"), which killed wine right after startup.
  # Clear the X bit of PT_GNU_STACK on every provider x86 library. (The
  # nixpkgs patchelf is too old for --clear-execstack, so flip the flag
  # directly; 64-bit ELF phdrs only.)
  python3 - <<'PYEOF'
import glob
import os
import struct

for path in glob.glob("rootfs/usr/lib/x86_64-linux-gnu/*.so*") + glob.glob(
    "rootfs/usr/lib64/*.so*"
):
    try:
        os.chmod(path, 0o644)  # store copies are 444; we own them here
        with open(path, "r+b") as f:
            data = f.read(64)
            if data[:4] != b"\x7fELF" or data[4] != 2:  # ELF64 only
                continue
            e_phoff = struct.unpack_from("<Q", data, 0x20)[0]
            e_phentsize = struct.unpack_from("<H", data, 0x36)[0]
            e_phnum = struct.unpack_from("<H", data, 0x38)[0]
            changed = False
            for i in range(e_phnum):
                off = e_phoff + i * e_phentsize
                f.seek(off)
                ph = bytearray(f.read(e_phentsize))
                p_type = struct.unpack_from("<I", ph, 0)[0]
                if p_type != 0x6474E551:  # PT_GNU_STACK
                    continue
                p_flags = struct.unpack_from("<I", ph, 4)[0]
                if p_flags & 0x1:
                    struct.pack_into("<I", ph, 4, p_flags & ~0x1)
                    f.seek(off)
                    f.write(ph)
                    changed = True
            if changed:
                print("cleared exec-stack:", path)
    except Exception as exc:  # noqa: BLE001 - best-effort header fixup
        print("skip", path, exc)
PYEOF
  chmod -R u+w rootfs/usr/lib/x86_64-linux-gnu rootfs/usr/lib64 2>/dev/null || true

  # Explicit fixups: the closure harvest can leave self-referencing symlinks
  # for files that appear in multiple store paths (libgcc_s ships in both
  # gcc-lib and gcc-libgcc; libstdc++ has SONAME aliases). Force-copy the
  # critical ones so the provider has real, readable files.
  for f in ${lib.getLib pkgs.stdenv.cc.cc.lib}/lib/lib*.so*; do
    [ -e "$f" ] && cp -aL --remove-destination "$f" rootfs/usr/lib/aarch64-linux-gnu/ || true
  done
  for f in ${lib.getLib pkgs.glibc}/lib/ld-linux-aarch64.so.1; do
    [ -e "$f" ] && cp -aL --remove-destination "$f" rootfs/usr/lib/aarch64-linux-gnu/ || true
  done

  # Staged, container-path-shaped copy of every provider-claimed x86
  # library, for generating the container-side ld.so.cache host-side (see
  # the steam wrapper: files/etc/runtime-ld.so.cache). Symlinks are enough —
  # ldconfig only records the scanned path strings.
  mkdir -p $ldso/usr/lib/x86_64-linux-gnu \
           $ldso/usr/lib/pressure-vessel/overrides/lib/x86_64-linux-gnu
  for f in rootfs/usr/lib/x86_64-linux-gnu/*; do
    # real ELF files only — dangling/dir symlinks (glibc's audit/) break ln
    r=$(readlink -f "$f" 2>/dev/null) || r=
    if [ -n "$r" ] && [ -f "$r" ]; then
      ln -s "$r" "$ldso/usr/lib/x86_64-linux-gnu/$(basename "$f")"
      ln -s "$r" "$ldso/usr/lib/pressure-vessel/overrides/lib/x86_64-linux-gnu/$(basename "$f")"
    fi
  done

  mkfs.erofs -zlz4 $out rootfs/
''
