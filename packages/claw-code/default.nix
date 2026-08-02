{
  lib,
  fetchFromGitHub,
  rustPlatform,
}:
rustPlatform.buildRustPackage rec {
  pname = "claw-code";
  version = "0.1.3";

  src = fetchFromGitHub {
    owner = "ultraworkers";
    repo = "claw-code";
    rev = "4ea31c1bc91c4e9bcbd67d51c550c01e127e6d0d";
    hash = "sha256-CCw6DVLL9kG7ESd5rldK+S2lLIatBBAuzFeG5eB0IMM=";
  };

  sourceRoot = "${src.name}/rust";

  cargoHash = "sha256-Acaycrxm3e87dx3P7NdWnivopF4xxaMi3PPbpSefEyY=";

  cargoBuildFlags = ["--package" "rusty-claude-cli"];

  doCheck = false;

  meta = with lib; {
    description = "Open-source clean-room rewrite of the Claude Code agent harness";
    homepage = "https://github.com/ultraworkers/claw-code";
    license = licenses.mit;
    mainProgram = "claw";
    maintainers = [];
  };
}
