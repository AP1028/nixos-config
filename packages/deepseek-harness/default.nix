# DeepSeek Harness (dsh) — pnpm monorepo, "everything is a plugin".
#
# Pin policy: the repo has no release tags (rapid developer preview); pin to a
# master commit and bump `rev` together with `version` (root package.json).
# Get the new src hash with:
#   nix store prefetch-file --json https://github.com/deepseek-ai/deepseek-harness/archive/<rev>.tar.gz
# Then set pnpmDeps.hash = "" and rebuild — the error reports the new store
# hash. The fetchPnpmDeps store is ~2 GB, so expect a long first build.

{
  lib,
  stdenv,
  fetchFromGitHub,
  nodejs_22,
  pnpm_11,
  pnpmConfigHook,
  fetchPnpmDeps,
  makeWrapper,
  musl,
  python3,
  gnumake,
}:

stdenv.mkDerivation (finalAttrs: {
  pname = "deepseek-harness";
  version = "0.1.0-rc.5";

  src = fetchFromGitHub {
    owner = "deepseek-ai";
    repo = "deepseek-harness";
    rev = "47f943859bef60e4160492346772ded9b24f765a";
    hash = "sha256-ZPGCNoPXVjP76Tm/tFPDX2X95cd83M4iHLmVP5dR+Ps=";
  };

  # pnpm 11 store snapshot (fetcherVersion 4: SQL-dump reproducibility).
  pnpmDeps = fetchPnpmDeps {
    inherit (finalAttrs) pname version;
    src = finalAttrs.src;
    fetcherVersion = 4;
    # registry stalls past pnpm's default 60s fetch timeout during the huge
    # initial parallel download; tolerate slow connections
    prePnpmInstall = "pnpm config set fetch-timeout 600000";
    hash = "sha256-aySHq0ywTMM5q7YuGHZrV3yQE3bwppgGfWH3wRnHCXk=";
  };

  nativeBuildInputs = [
    nodejs_22
    pnpm_11
    pnpmConfigHook
    makeWrapper
    # node-gyp toolchain: pnpmConfigHook installs with --ignore-scripts, so
    # node-pty's `install` (prebuild check -> `node-gyp rebuild`) never ran
    python3
    gnumake
  ];

  # The landlock-run launcher binary is gitignored (upstream CI builds it
  # per-arch); compile the checked-in C source statically against musl, exactly
  # like upstream's native/landlock-run/scripts/build.ts does, into the
  # platform package the JS entry probes at runtime. Upstream package dirs use
  # node arch naming (linux-x64 / linux-arm64), hence stdenv.node.arch.
  # musl must NOT be in nativeBuildInputs: stdenv then injects
  # -isystem ...musl/include ahead of glibc, and musl's <features.h> (no
  # __GLIBC_PREREQ) breaks the C++ toolchain. Call musl-gcc by absolute path.
  preBuild = ''
    mkdir -p native/landlock-run/packages/linux-${stdenv.hostPlatform.node.arch}/bin
    ${musl.dev}/bin/musl-gcc -std=c11 -Os -Wall -Wextra -Werror -static -s \
      -o native/landlock-run/packages/linux-${stdenv.hostPlatform.node.arch}/bin/landlock-run \
      native/landlock-run/packages/entry/src/main.c
  '';

  buildPhase = ''
    runHook preBuild

    # node-pty ships no linux-x64 prebuilt binary and its install script
    # (prebuild check -> node-gyp rebuild) is skipped by --ignore-scripts, so
    # build it explicitly. node-gyp finds the node headers via the nix node.
    (cd $(echo node_modules/.pnpm/node-pty@*/node_modules/node-pty) && \
      node ${nodejs_22}/lib/node_modules/npm/node_modules/node-gyp/bin/node-gyp.js rebuild)

    pnpm run build
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out/lib/dsh $out/bin
    cp -r . $out/lib/dsh/

    # lib/bin.js is the production CLI entry (the root "dsh" script runs the
    # src/ copy through tsx for development). The package resolves plugins and
    # the web frontend from its own node_modules, so the whole tree stays put.
    # --expose-internals: the node-addon-require-builtin prebuilt addon used to
    # reach Node's internal module loader throws on the nixpkgs node builds
    # (V8 layout mismatch), so we take the code's own native fallback instead.
    makeWrapper ${lib.getExe nodejs_22} $out/bin/dsh \
      --add-flags "--expose-internals $out/lib/dsh/apps/cli/lib/bin.js"

    runHook postInstall
  '';

  meta = with lib; {
    description = "DeepSeek AI agent harness (dsh) — everything is a plugin";
    homepage = "https://github.com/deepseek-ai/deepseek-harness";
    license = licenses.mit;
    platforms = platforms.linux;
    mainProgram = "dsh";
  };
})
