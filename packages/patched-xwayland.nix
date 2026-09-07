# Xwayland with the composite restore blit disabled.
#
# Root cause of the Cadence DE-freeze (docs/handoff.md): when a client whose
# composite damage chain got corrupted disconnects, Xwayland's single dispatch
# thread spins forever in
#
#   CloseDownClient -> FreeClientResources -> DeleteWindow -> UnmapWindow
#     -> compUnrealizeWindow -> compRestoreWindow -> damageCopyArea
#     -> damageRegionProcessPending
#
# freezing the whole DE. The ONLY door to the spinning loop from that stack is
# the GC CopyArea blit inside compRestoreWindow (installed as damageCopyArea by
# the damage extension): `call *0x18(%rax)` at vaddr/file-offset 0x101c91 in
# xwayland-24.1.13. NOPing it skips only the restore copy - purely cosmetic in
# a compositing Wayland session (kwin renders windows from its own buffers) -
# while keeping all of compRestoreWindow's bookkeeping.
#
# Install with lib.hiPrio so it shadows xorg.xwayland's bin/Xwayland in
# /run/current-system/sw/bin: kwin launches Xwayland via PATH (verified:
# argv[0] is /run/current-system/sw/bin/Xwayland).
#
# The byte check makes a nixpkgs bump fail the build instead of blind-patching
# a changed binary; re-derive the offset then (nm -> compRestoreWindow, first
# `call *0x18(%rax)` after the ValidateGC call).
{
  lib,
  runCommand,
  xwayland,
}:
runCommand "xwayland-comp-restore-bypass"
  {
    meta = with lib; {
      description = "xwayland-24.1.13 with the compRestoreWindow blit NOPed (Cadence DE-freeze workaround)";
      platforms = platforms.linux;
    };
  }
  ''
    install -Dm755 ${xwayland}/bin/Xwayland $out/bin/Xwayland

    expect='ff5018'
    got=$(dd if=$out/bin/Xwayland bs=1 skip=$((0x101c91)) count=3 status=none | od -An -tx1 | tr -d ' \n')
    if [ "$got" != "$expect" ]; then
      echo "Xwayland bytes at 0x101c91 are '$got', expected '$expect'" \
           "- xwayland changed, refusing to blind-patch" >&2
      exit 1
    fi
    printf '\x90\x90\x90' | dd of=$out/bin/Xwayland bs=1 seek=$((0x101c91)) conv=notrunc status=none

    # sanity: the patched binary must still run
    $out/bin/Xwayland -version >/dev/null
  ''
