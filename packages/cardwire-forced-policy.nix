# Overlay: give nixpkgs' cardwire a *persistent* per-application "force dGPU"
# policy, so an application can be pinned to the dGPU without injecting
# CARDWIRE_FORCE_DGPU=1 into every launch (which for Steam games would mean a
# per-game launch option, because a game inherits the environment of the
# already-running Steam client, not of whatever launched the shortcut).
#
# The patch (packages/patches/cardwire-forced-app-policy.patch) does three
# things on top of nixpkgs' cardwire 0.12.1:
#
#   1. adds `GpuPolicy::Forced = 2` (Blocked/Allowed only exist in 0.12.x *and*
#      upstream main), persisted in /var/lib/cardwire/cardwire.db;
#   2. makes the analyzer resolve that policy to the eBPF "forced" map with
#      gpu id 1 (dGPU), i.e. the persistent equivalent of
#      CARDWIRE_FORCE_DGPU=1, decided at exec time and therefore *before* the
#      application enumerates GPUs;
#   3. fixes RequestProcessAccess, which aborted with `bpf_map_delete_elem
#      failed` for any pid not already tracked, because it removed the pid from
#      the other map with `?`. Per-app forcing via D-Bus now works for
#      untracked pids too.
#
# The GUI additionally labels policy 2 as "Forced (dGPU)" and keeps it forced
# when re-enabled.
#
# The seeding of Steam app ids is done by the cardwire module
# (modules/hardware/cardwire.nix); this file only carries the patch.
final: prev: {
  cardwire = prev.cardwire.overrideAttrs (old: {
    patches = (old.patches or []) ++ [ ./patches/cardwire-forced-app-policy.patch ];
  });
}
