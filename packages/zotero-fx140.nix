# Zotero 10.0.x built against the Gecko runtime it actually pins.
#
# nixpkgs switched pkgs.zotero to firefox-esr-153-unwrapped when it dropped
# firefox-esr-140 (NixOS/nixpkgs#568692), but Zotero 10.0.2's build scripts
# expect GECKO_VERSION_LINUX="140.15.0esr" (app/config.sh) and abort on
# Firefox 153's reworked omni.ja layout: modules/ActorManagerParent.sys.mjs
# no longer contains "AboutTranslations: {" (it moved to
# "JSWINDOWACTORS.AboutTranslations = {"), so fetch_xulrunner aborts.
#
# Pass in a nixpkgs firefox-esr-140-unwrapped: unstable dropped it, but the
# nixpkgs-stable track still tracks the ESR branch (140.17.0esr at the pinned
# rev; it never went EOL there). A nix-built runtime is required -- Mozilla's
# release tarballs carry no Nix RUNPATHs, so the GTK/NSS/etc. libs they
# dlopen cannot be resolved in the store (libmozgtk.so -> libgtk-3.so.0).
# Drop this override once zotero requires Gecko >= 153.
{ firefox-esr-140-unwrapped, zotero }:
zotero.override { firefox-esr-153-unwrapped = firefox-esr-140-unwrapped; }
