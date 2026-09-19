{
  lib,
  fetchFromGitHub,
  rustPlatform,
}:
rustPlatform.buildRustPackage rec {
  pname = "virtuoso-cli";
  version = "1.3.5";

  src = fetchFromGitHub {
    owner = "deanyou";
    repo = "virtuoso-cli";
    rev = "23f4e4514f5fba274d671308bab1845293065e24";
    hash = "sha256-6ug96heBEW5ntaWARaFLj/1WPSR7+gyhq5SncipVbwU=";
  };

  # Upstream does not track Cargo.lock; vendor from the pinned lock file we
  # generated and drop it into the source tree before cargoSetupHook checks it.
  cargoLock.lockFile = ./Cargo.lock;

  postPatch = ''
    cp ${./Cargo.lock} Cargo.lock
  '';

  # vcli/vtui build unconditionally; virtuoso-daemon is behind the `daemon`
  # feature ([[bin]] required-features).
  buildFeatures = ["daemon"];

  # Upstream tests exercise SSH/tunnel transports and a live bridge daemon.
  doCheck = false;

  # Deploy-time daemon path substitution, same as install.sh: the bridge
  # resolves the daemon from this baked path inside Virtuoso's CIW.
  postInstall = ''
    mkdir -p $out/share/virtuoso-cli
    cp resources/ramic_bridge.il $out/share/virtuoso-cli/ramic_bridge.il
    substituteInPlace $out/share/virtuoso-cli/ramic_bridge.il \
      --replace-fail '__DAEMON_PATH__' "$out/bin/virtuoso-daemon"
  '';

  meta = with lib; {
    description = "Bridge and CLI for controlling Cadence Virtuoso from outside, designed for AI agents and humans";
    homepage = "https://github.com/deanyou/virtuoso-cli";
    license = licenses.mit;
    mainProgram = "vcli";
    maintainers = [];
  };
}
