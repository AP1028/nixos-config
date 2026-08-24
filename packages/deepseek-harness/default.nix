# DeepSeek Harness (dsh) — built from the upstream monorepo at dsh-v0.1.0-rc.8
# (commit 141eb6fef83422698aef7a981029e843e8161534).
#
# Uses the upstream pnpm-lock.yaml via fetchPnpmDeps and builds the TS/web
# workspace with pnpmBuildHook. The whole tree is shipped because dsh resolves
# workspace packages in-tree at runtime (linkWorkspacePackages), so the loader's
# bare imports of workspace specifiers need the mirrored root node_modules.
#
# Compared with the open nixpkgs PRs:
# - #552467: source-based build, Nix bash default, native landlock-run compiler
#   substitution, pnpm/Node runtime handling.
# - #553134: npm-artifact packaging; this config replaces that with upstream
#   source now that a matching public tag exists.
# - #554081: simplified pnpm build + web boot test; we keep its install layout
#   and add back native landlock, Nix bash, slim Node runtime, and richer
#   install checks.
#
# Update notes: bump `version`, `rev`/`hash`, and the `fetchPnpmDeps` hash. The
# source tarball has no .git, so also update `DSH_CLIENT_COMMIT_HASH` in
# `preBuild` to the new pinned commit.

{
  lib,
  stdenv,
  bashInteractive,
  fetchFromGitHub,
  fetchPnpmDeps,
  makeBinaryWrapper,
  nodejs_24,
  nodejs-slim_24,
  pkgsStatic,
  pnpm_11,
  pnpmBuildHook,
  pnpmConfigHook,
  versionCheckHook,
}:

let
  runtimeNode = nodejs-slim_24;
  runtimePnpm = pnpm_11.override { nodejs-slim = runtimeNode; };
in
stdenv.mkDerivation (finalAttrs: {
  pname = "deepseek-harness";
  version = "0.1.0-rc.8";

  src = fetchFromGitHub {
    owner = "deepseek-ai";
    repo = "deepseek-harness";
    rev = "141eb6fef83422698aef7a981029e843e8161534";
    hash = "sha256-FzToX43k6upXkwTxTYXHRK5IdatxibxeZgZBpuDE7S4=";
  };

  # fetchPnpmDeps downloads the entire dependency tree (several GB of
  # cross-platform binaries) in one shot and dies on the first network blip.
  # The stock installPhase is therefore overridden to:
  #  - keep the pnpm store in a persistent dir for the whole builder run, so
  #    retried attempts resume already-downloaded packages instead of starting
  #    over;
  #  - configure pnpm itself with many more fetch retries and much longer
  #    timeouts;
  #  - retry the whole `pnpm install` up to 5 times before giving up.
  #
  # The pinned output hash is unaffected: the fixup phase normalizes the store
  # (sorted json, fixed permissions, sorted tar, dumped sqlite), so the output
  # is byte-identical however the downloads landed.
  pnpmDeps = (fetchPnpmDeps {
    inherit (finalAttrs) pname version src;
    pnpm = pnpm_11;
    fetcherVersion = 4;
    hash = "sha256-+PsdK9u3ZKv4XtSc8tBKKP48J/95/CGTMIUf8Q8dbok=";
  }).overrideAttrs (old: {
    installPhase = ''
      runHook preInstall

      mkdir -p $out
      storePath="$HOME/dsh-pnpm-store"

      versionAtLeast () {
        local cur_version=$1 min_version=$2
        printf "%s\0%s" "$min_version" "$cur_version" | sort -zVC
      }

      lockfileVersion="$(yq -r .lockfileVersion pnpm-lock.yaml)"
      if [[ ''${lockfileVersion:0:1} -gt ${lib.versions.major pnpm_11.version} ]]; then
        echo "ERROR: lockfileVersion $lockfileVersion in pnpm-lock.yaml is too new for pnpm ${lib.versions.major pnpm_11.version}!"
        exit 1
      fi

      pushd "$HOME"
      pnpmVersion=$(pnpm --version)
      if versionAtLeast "$pnpmVersion" "11"; then
        export pnpm_config_pm_on_fail=ignore
        export pnpm_config_side_effects_cache=false
        export pnpm_config_update_notifier=false
      fi
      pnpm config set store-dir "$storePath"
      # Tolerate a flaky network: retry individual package fetches up to 10
      # times with backoff, and allow a single fetch up to 10 minutes.
      pnpm config set fetch-retries 10
      pnpm config set fetch-retry-mintimeout 5000
      pnpm config set fetch-retry-maxtimeout 120000
      pnpm config set fetch-timeout 600000
      popd

      for attempt in 1 2 3 4 5; do
        echo "=== dsh pnpm fetch: attempt $attempt of 5 ==="
        # Drop incomplete downloads left behind by a failed attempt.
        rm -rf "$storePath"/{v3,v10,v11}/tmp
        if pnpm install \
            --force \
            --ignore-scripts \
            --registry="$NIX_NPM_REGISTRY" \
            --frozen-lockfile; then
          break
        fi
        if [ "$attempt" -ge 5 ]; then
          echo "pnpm install failed after 5 attempts" >&2
          exit 1
        fi
        echo "pnpm install failed on attempt $attempt; retrying in 30s" >&2
        sleep 30
      done

      echo 4 > $out/.fetcher-version

      runHook postInstall
    '';
  });

  nativeBuildInputs = [
    makeBinaryWrapper
    nodejs_24
    pnpm_11
    pnpmConfigHook
    pnpmBuildHook
  ];

  postPatch = ''
    # Nixpkgs' static musl compiler replaces upstream's expected musl-gcc.
    substituteInPlace native/landlock-run/scripts/build.ts \
      --replace-fail \
        "'musl-gcc'" \
        "'${lib.getExe pkgsStatic.stdenv.cc}'"

    # NixOS does not provide /bin/bash; default terminal-bash to a store path.
    substituteInPlace packages/terminal/terminal-bash/src/config.ts \
      --replace-fail \
        "export const DEFAULT_BASH_SHELL = '/bin/bash'" \
        "export const DEFAULT_BASH_SHELL = '${lib.getExe bashInteractive}'"

    # Keep CSS virtual module ids relative so built client bundles do not embed
    # the Nix build root (/build/source/...) in their generated comments.
    substituteInPlace packages/client/tsdown.client.ts \
      --replace-fail \
        "return CSS_VIRTUAL_PREFIX + abs + CSS_VIRTUAL_SUFFIX" \
        "return CSS_VIRTUAL_PREFIX + relative(process.cwd(), abs) + CSS_VIRTUAL_SUFFIX" \
      --replace-fail \
        "return INLINE_CSS_VIRTUAL_PREFIX + abs + CSS_VIRTUAL_SUFFIX" \
        "return INLINE_CSS_VIRTUAL_PREFIX + relative(process.cwd(), abs) + CSS_VIRTUAL_SUFFIX" \
      --replace-fail \
        "return GLOBAL_CSS_VIRTUAL_PREFIX + abs + CSS_VIRTUAL_SUFFIX" \
        "return GLOBAL_CSS_VIRTUAL_PREFIX + relative(process.cwd(), abs) + CSS_VIRTUAL_SUFFIX" \
      --replace-fail \
        "const fileId = virtualId.slice(CSS_VIRTUAL_PREFIX.length, -CSS_VIRTUAL_SUFFIX.length)" \
        "const fileId = resolvePath(virtualId.slice(CSS_VIRTUAL_PREFIX.length, -CSS_VIRTUAL_SUFFIX.length))" \
      --replace-fail \
        "const fileId = virtualId.slice(INLINE_CSS_VIRTUAL_PREFIX.length, -CSS_VIRTUAL_SUFFIX.length)" \
        "const fileId = resolvePath(virtualId.slice(INLINE_CSS_VIRTUAL_PREFIX.length, -CSS_VIRTUAL_SUFFIX.length))" \
      --replace-fail \
        "const fileId = virtualId.slice(GLOBAL_CSS_VIRTUAL_PREFIX.length, -CSS_VIRTUAL_SUFFIX.length)" \
        "const fileId = resolvePath(virtualId.slice(GLOBAL_CSS_VIRTUAL_PREFIX.length, -CSS_VIRTUAL_SUFFIX.length))"
  '';

  dontPatchShebangs = true;

  preBuild = ''
    # Source tarballs do not include .git; supply the pinned commit hash that
    # scripts/client-build-environment.ts embeds into client artifacts.
    export DSH_CLIENT_COMMIT_HASH=141eb6f
  '';

  postBuild = ''
    pnpm --dir native/landlock-run run build:native
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out/libexec/dsh
    cp -r . $out/libexec/dsh/

    # Optional cross-platform binary packages leave dangling symlinks in
    # node_modules/.pnpm; drop them so the fixup phase passes.
    find $out/libexec/dsh/node_modules/.pnpm -type l ! -exec test -e {} \; -delete

    # pnpm only links workspace packages into each dependent package's own
    # node_modules, so the loader's bare `import(name)` cannot resolve workspace
    # specifiers from its own directory. Mirror the virtual store's scoped
    # packages into the root node_modules so bare specifiers resolve anywhere.
    shopt -s nullglob
    store_scopes=("$out/libexec/dsh/node_modules/.pnpm/node_modules/"@*/)
    for scope in "''${store_scopes[@]}"; do
      scope_name=$(basename "$scope")
      mkdir -p "$out/libexec/dsh/node_modules/$scope_name"
      for pkg in "$scope"*; do
        ln -sfn "../.pnpm/node_modules/$scope_name/$(basename "$pkg")" \
          "$out/libexec/dsh/node_modules/$scope_name/$(basename "$pkg")"
      done
    done

    # Use the slimmer runtime Node and keep pnpm available for `dsh plugin`.
    while IFS= read -r file; do
      substituteInPlace "$file" \
        --replace-warn ${lib.getExe nodejs_24} ${lib.getExe runtimeNode}
    done < <(find "$out/libexec/dsh" -type f -exec grep -IlF ${lib.getExe nodejs_24} {} +)

    makeBinaryWrapper ${lib.getExe runtimeNode} $out/bin/dsh \
      --add-flags "--expose-internals" \
      --add-flags "$out/libexec/dsh/apps/cli/lib/bin.js" \
      --prefix PATH : ${lib.makeBinPath [ runtimeNode runtimePnpm ]}

    runHook postInstall
  '';

  doInstallCheck = true;
  nativeInstallCheckInputs = [ versionCheckHook ];
  versionCheckProgramArg = "--version";

  postInstallCheck = ''
    app="$out/libexec/dsh"

    "$out/bin/dsh" --help > /dev/null
    DSH_HOME="$(mktemp -d)" \
      "$out/bin/dsh" --profile headless --dump-default-config > /dev/null
    DSH_HOME="$(mktemp -d)" \
      "$out/bin/dsh" plugin --profile install-check --version \
      | grep -Fx ${lib.escapeShellArg runtimePnpm.version}

    webLog="$(mktemp)"
    DSH_HOME="$(mktemp -d)" \
      "$out/bin/dsh" web --host 127.0.0.1 --port 0 --no-open > "$webLog" 2>&1 &
    webPid=$!

    cleanupWeb() {
      kill "$webPid" 2> /dev/null || true
      wait "$webPid" 2> /dev/null || true
    }

    trap cleanupWeb EXIT

    for _ in {1..100}; do
      if ! kill -0 "$webPid" 2> /dev/null; then
        cat "$webLog" >&2
        exit 1
      fi
      webUrl="$(sed -n 's/^dsh web: //p' "$webLog")"
      if [ -n "$webUrl" ]; then
        break
      fi
      sleep 0.1
    done
    test -n "''${webUrl:-}"
    WEB_URL="$webUrl" ${lib.getExe runtimeNode} <<'NODE'
    const response = await fetch(process.env.WEB_URL);
    if (!response.ok || !(await response.text()).includes("<html")) process.exit(1);
    NODE

    cleanupWeb
    trap - EXIT

    ptyPkg="$(find "$app/node_modules/.pnpm" -path '*/node_modules/node-pty/package.json' -print -quit)"
    koffiPkg="$(find "$app/node_modules/.pnpm" -path '*/node_modules/koffi/package.json' -print -quit)"
    addonPkg="$(find "$app/node_modules/.pnpm" -path '*/node_modules/node-addon-require-builtin/package.json' -print -quit)"
    sharpPkg="$(find "$app/node_modules/.pnpm" -path '*/node_modules/sharp/package.json' -print -quit)"
    test -n "$ptyPkg" -a -n "$koffiPkg" -a -n "$addonPkg" -a -n "$sharpPkg"
    PTY="$(dirname "$ptyPkg")" KOFFI="$(dirname "$koffiPkg")" \
      ADDON="$(dirname "$addonPkg")" SHARP="$(dirname "$sharpPkg")" \
      ${lib.getExe runtimeNode} <<'NODE'
    const path = require("node:path");
    const pty = require(process.env.PTY);
    const koffi = require(process.env.KOFFI);
    const addon = require(process.env.ADDON);
    const sharp = require(process.env.SHARP);

    const child = pty.spawn("${stdenv.shell}", ["-c", "printf pty-ok"], {
      cols: 80,
      rows: 24,
    });
    let output = "";
    child.onData((data) => output += data);
    child.onExit(({ exitCode }) => {
      if (exitCode !== 0 || !output.includes("pty-ok")) process.exit(1);
    });
    NODE

    landlock="$app/native/landlock-run/packages/linux-x64/bin/landlock-run"
    test -x "$landlock"
    "$landlock" --probe | grep -Eq '^landlock: (fully|partially) enforced$'

    if find "$app" -type l ! -exec test -e {} \; -print -quit | grep -q .; then
      find "$app" -type l ! -exec test -e {} \; -print >&2
      exit 1
    fi

    if grep -RIlE --exclude-dir=node_modules '/build/(source|tmp\.|\.home)' "$app"; then
      exit 1
    fi
  '';

  meta = {
    description = "AI agent harness with a plugin-based architecture";
    homepage = "https://github.com/deepseek-ai/deepseek-harness";
    downloadPage = "https://www.npmjs.com/package/@deepseek-ai/dsh";
    license = lib.licenses.mit;
    mainProgram = "dsh";
    platforms = [ "x86_64-linux" ];
    sourceProvenance = with lib.sourceTypes; [
      fromSource
      binaryNativeCode
    ];
  };
})
