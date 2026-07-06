{
  lib,
  stdenv,
  fetchurl,
  makeWrapper,
  perl,
  bash,
  coreutils,
  gnused,
  gnugrep,
  gawk,
  gnutar,
  gzip,
  curl,
  iproute2,
  iptables,
  nftables,
  ipset,
  kmod,
  procps,
  # Bump these together. Latest version + tarball hash are published at
  #   https://router.uu.163.com/api/plugin?type=steam-deck-plugin-x86_64
  # which returns "<url>,<md5>". Grab the version from the URL and run
  #   nix store prefetch-file <url>
  # to get the SRI hash.
  version ? "14.2.3",
  hash ? "sha256-qPG3zX9qhDQ36StyWaiC2sgRq3VXQ4PdfzrvZWAGQco=",
}:
stdenv.mkDerivation (finalAttrs: {
  pname = "uudeck";
  inherit version;

  src = fetchurl {
    url = "https://uurouter.gdl.netease.com/uuplugin/steam-deck-plugin-x86_64/v${version}/uu.tar.gz";
    inherit hash;
  };

  # Tarball extracts uu.conf, uuplugin and xuplugin-guardian with no top-level dir.
  sourceRoot = ".";

  nativeBuildInputs = [makeWrapper perl];

  # The plugin shells out (via system() -> /bin/sh) to these tools at runtime to
  # program routes, nftables/iptables rules, ipsets and kernel modules. Baking
  # them onto PATH keeps the package self-contained regardless of the caller.
  passthru.runtimePath = lib.makeBinPath [
    bash
    coreutils
    gnused
    gnugrep
    gawk
    gnutar
    gzip
    curl
    iproute2
    iptables
    nftables
    ipset
    kmod
    procps
  ];

  installPhase = ''
    runHook preInstall

    mkdir -p $out/libexec/uudeck $out/bin

    # The stock binary stores its persistent device UUID at the read-only,
    # non-existent-on-NixOS path /usr/sbin/uu/.uuplugin_uuid. Rewrite it in place
    # to /var/lib/uu/.uuplugin_uuid (the service StateDirectory) so bindings
    # survive reboots without re-pairing in the phone app. The replacement is one
    # byte shorter and NUL-padded, so every ELF offset is preserved.
    install -m0755 uuplugin $out/libexec/uudeck/uuplugin
    perl -0777 -i -pe \
      's{/usr/sbin/uu/\.uuplugin_uuid}{/var/lib/uu/.uuplugin_uuid\x00}g' \
      $out/libexec/uudeck/uuplugin
    grep -q '/var/lib/uu/.uuplugin_uuid' $out/libexec/uudeck/uuplugin

    install -m0755 xuplugin-guardian $out/libexec/uudeck/xuplugin-guardian
    install -m0644 uu.conf $out/libexec/uudeck/uu.conf

    # uudeck <config-path> — runs with the runtime tools on PATH. The service is
    # expected to set WorkingDirectory to a writable dir that also holds
    # ./xuplugin-guardian (spawned relative to the cwd).
    makeWrapper $out/libexec/uudeck/uuplugin $out/bin/uudeck \
      --prefix PATH : ${finalAttrs.passthru.runtimePath}

    runHook postInstall
  '';

  meta = with lib; {
    description = "NetEase UU game accelerator, Steam Deck plugin (patched for NixOS)";
    homepage = "https://uu.163.com/";
    license = licenses.unfree;
    platforms = ["x86_64-linux"];
    mainProgram = "uudeck";
  };
})
