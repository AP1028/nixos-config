final: prev: {
  supergfxctl = prev.rustPlatform.buildRustPackage rec {
    pname = "supergfxctl";
    version = "git-2026-05-09";

    src = final.fetchFromGitLab {
      domain = "gitlab.com";
      owner = "asus-linux";
      repo = "supergfxctl";
      rev = "5d503b1efd41f29f77679513890807c0c0a576fe";
      hash = "sha256-2UH+/a4p0zJu1tosL3+dg91tEK74AtaYOO0lRJdhSOU=";
    };

    cargoHash = "sha256-BM/fcXWyEWjAkqOdj2MItOzKknNUe9HMns30H1n5/xo=";

    postPatch = ''
      substituteInPlace data/supergfxd.service --replace /usr/bin/supergfxd $out/bin/supergfxd
      substituteInPlace data/99-nvidia-ac.rules --replace /usr/bin/systemctl ${final.systemd}/bin/systemctl
    '';

    nativeBuildInputs = with final; [pkg-config udevCheckHook];
    buildInputs = [final.systemd];

    doCheck = false;
    doInstallCheck = true;

    postInstall = ''
      install -Dm444 -t $out/lib/udev/rules.d/ data/*.rules
      install -Dm444 -t $out/share/dbus-1/system.d/ data/org.supergfxctl.Daemon.conf
      install -Dm444 -t $out/lib/systemd/system/ data/supergfxd.service
    '';

    meta = with final.lib; {
      description = "GPU switching utility, mostly for ASUS laptops (custom Git build)";
      homepage = "https://gitlab.com/asus-linux/supergfxctl";
      license = licenses.mpl20;
      platforms = ["x86_64-linux"];
      maintainers = [maintainers.k900];
    };
  };
}
