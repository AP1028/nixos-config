# Xwayland with the composite restore blit disabled.
#
# Root cause of the Cadence DE-freeze (docs/cadence-freeze.md): when a client whose
# composite damage chain got corrupted disconnects, Xwayland's single dispatch
# thread spins forever in
#
#   CloseDownClient -> FreeClientResources -> DeleteWindow -> UnmapWindow
#     -> compUnrealizeWindow -> compCheckRedirect -> compRestoreWindow
#     -> damageCopyArea -> damageRegionProcessPending
#
# freezing the whole DE. The ONLY door to the spinning loop from that stack is
# the GC CopyArea blit inside compRestoreWindow (installed as damageCopyArea by
# the damage extension). +0x18 is the arch-independent ops->CopyArea offset in
# the GC ops struct; the call encoding differs per arch:
#
#   x86_64-linux   ff 50 18        call *0x18(%rax)             -> 90 90 90
#   aarch64-linux  f940.. d63f..   ldr xN,[xM,#0x18]; blr xN    -> d503201f (nop)
#
# NOPing it skips only the restore copy - purely cosmetic in a compositing
# Wayland session (kwin renders windows from its own buffers) - while keeping
# all of compRestoreWindow's bookkeeping.
#
# The site is not baked in: patch-xwayland-comp-restore.py reads
# compRestoreWindow's address/size from .symtab and finds the unique GC-ops
# CopyArea call inside it, so nixpkgs bumps that merely shift the binary keep
# working. If the symbols disappear or the pattern stops being unique, the
# build fails loudly instead of blind-patching (re-derive with nm/objdump per
# the runbook in docs/cadence-freeze.md).
#
# Install with lib.hiPrio so it shadows xorg.xwayland's bin/Xwayland in
# /run/current-system/sw/bin: kwin launches Xwayland via PATH (verified on
# both asusg16 and the macbook: live argv[0] is the sw path).
{
  lib,
  runCommand,
  xwayland,
  python3,
}:
runCommand "xwayland-comp-restore-bypass" {
  nativeBuildInputs = [python3];
  meta = with lib; {
    description = "Xwayland with the compRestoreWindow blit NOPed (Cadence DE-freeze workaround)";
    platforms = platforms.linux;
  };
} ''
  install -Dm755 ${xwayland}/bin/Xwayland $out/bin/Xwayland
  python3 ${./patch-xwayland-comp-restore.py} $out/bin/Xwayland

  # sanity: the patched binary must still run
  $out/bin/Xwayland -version >/dev/null
''
