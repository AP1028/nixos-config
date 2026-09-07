# Xwayland with the composite restore blit disabled.
#
# Root cause of the Cadence DE-freeze (docs/handoff.md): when a client whose
# composite damage chain got corrupted disconnects, Xwayland's single dispatch
# thread spins forever in
#
#   CloseDownClient -> FreeClientResources -> DeleteWindow -> UnmapWindow
#     -> compUnrealizeWindow -> compCheckRedirect -> compRestoreWindow
#     -> damageCopyArea -> damageRegionProcessPending
#
# freezing the whole DE. The ONLY door to the spinning loop from that stack is
# the GC CopyArea blit inside compRestoreWindow (installed as damageCopyArea by
# the damage extension). The GC ops struct offset is arch-independent (+0x18);
# the call encoding and its site differ per arch:
#
#   x86_64-linux  file off 0x101c91: ff 50 18        (call *0x18(%rax)) -> 3x nop
#   aarch64-linux file off 0x fc5c4: 40 01 3f d6     (blr x10)          -> nop (d503201f)
#
# (both on xwayland-24.1.13; text segment maps vaddr to file offset 1:1).
# NOPing it skips only the restore copy - purely cosmetic in a compositing
# Wayland session (kwin renders windows from its own buffers) - while keeping
# all of compRestoreWindow's bookkeeping.
#
# Install with lib.hiPrio so it shadows xorg.xwayland's bin/Xwayland in
# /run/current-system/sw/bin: kwin launches Xwayland via PATH (verified on
# both asusg16 and the macbook: live argv[0] is the sw path).
#
# The byte check makes a nixpkgs bump fail the build instead of blind-patching
# a changed binary; re-derive the offset then (nm -> compRestoreWindow, first
# `call *0x18(%rax)` / `blr` after the ValidateGC call).
{
  lib,
  runCommand,
  xwayland,
  stdenv,
}: let
  sites = {
    x86_64-linux = {
      offset = "0x101c91";
      expect = "ff5018";
      new = "909090";
    };
    aarch64-linux = {
      offset = "0xfc5c4";
      expect = "40013fd6";
      new = "1f2003d5";
    };
  };
  site =
    sites.${stdenv.hostPlatform.system}
    or (throw "patched-xwayland: no patch site for ${stdenv.hostPlatform.system}");
  count = builtins.div (builtins.stringLength site.expect) 2;
  # "ff5018" -> "\xff\x50\x18" for printf
  hexBytes = h:
    builtins.concatStringsSep "" (
      map (p: "\\x" + builtins.head p) (
        builtins.filter builtins.isList (builtins.split "([0-9a-f]{2})" h)
      )
    );
in
  runCommand "xwayland-comp-restore-bypass"
    {
      meta = with lib; {
        description = "Xwayland 24.1.13 with the compRestoreWindow blit NOPed (Cadence DE-freeze workaround)";
        platforms = with platforms; linux;
      };
    }
    ''
      install -Dm755 ${xwayland}/bin/Xwayland $out/bin/Xwayland

      got=$(dd if=$out/bin/Xwayland bs=1 skip=$(( ${site.offset} )) count=${toString count} status=none | od -An -tx1 | tr -d ' \n')
      if [ "$got" != "${site.expect}" ]; then
        echo "Xwayland bytes at ${site.offset} are '$got', expected '${site.expect}'" \
             "- xwayland changed, refusing to blind-patch" >&2
        exit 1
      fi
      printf '${hexBytes site.new}' | dd of=$out/bin/Xwayland bs=1 seek=$(( ${site.offset} )) conv=notrunc status=none

      # sanity: the patched binary must still run
      $out/bin/Xwayland -version >/dev/null
    ''
