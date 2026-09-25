# DeepSeek Harness (dsh) — built from the upstream monorepo at dsh-v0.1.7-rc.2
# (commit 477b4f420553e8a52c2fbccc464d7561b239c443).
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
#   and add back native landlock, Nix bash, official Node runtime, and richer
#   install checks.
#
# The Electron desktop client is packaged from the same tree: upstream has no
# Linux release, so the shell runs unpackaged ("development" mode) against the
# built workspace, with a desktop-runtime.json descriptor and a "primary
# runtime" payload (pinned Node, Python, and Office wheels) assembled from
# scripts/primary-runtime/lock.json. `dsh-desktop` wraps the Nixpkgs Electron.
#
# Update notes: bump `version`, `rev`/`hash`, and the `fetchPnpmDeps` hash. The
# source tarball has no .git, so also update `DSH_CLIENT_COMMIT_HASH` in
# `preBuild` to the new pinned commit. Bump `nodeRuntimeVersion` (and its hash)
# when upstream moves to a Node release the current runtime cannot run. The
# primary-runtime assets are read from the pinned source's lock.json, so no
# hashes change there; bump `desktopProtocolVersion` when upstream's
# apps/desktop/src/host-protocol.ts does.

{
  lib,
  stdenv,
  bashInteractive,
  electron_44,
  fetchFromGitHub,
  fetchPnpmDeps,
  fetchurl,
  glibc,
  makeBinaryWrapper,
  makeWrapper,
  nodejs_24,
  nodejs-slim_24,
  patchelf,
  pkgsStatic,
  pnpm_11,
  pnpmBuildHook,
  pnpmConfigHook,
  versionCheckHook,
  zlib,
}:

let
  # dsh's profile resolution loads internal Node modules through
  # node-addon-require-builtin, whose native addon pattern-matches the getter
  # code inside the running Node executable. The Nixpkgs-built Node is not
  # recognized (GCC emits an extra `xor edi,edi` before the getter's `ret`),
  # so the runtime is the official upstream build, patched to run on NixOS.
  # The Nixpkgs Node still drives the pnpm build.
  nodeRuntimeVersion = "24.19.0";

  runtimeNode = stdenv.mkDerivation {
    pname = "dsh-runtime-node";
    version = nodeRuntimeVersion;

    src = fetchurl {
      url = "https://nodejs.org/dist/v${nodeRuntimeVersion}/node-v${nodeRuntimeVersion}-linux-x64.tar.xz";
      hash = "sha256-FLNC5xIE+BG95hU76OBLYq72PCNv75K1X5yDFUtAlkc=";
    };

    nativeBuildInputs = [ patchelf ];

    dontConfigure = true;
    dontBuild = true;
    dontStrip = true;
    dontPatchELF = true;

    installPhase = ''
      runHook preInstall

      mkdir -p $out/bin
      cp bin/node $out/bin/node
      patchelf \
        --set-interpreter ${stdenv.cc.bintools.dynamicLinker} \
        --set-rpath ${lib.makeLibraryPath [ glibc stdenv.cc.cc.lib ]} \
        $out/bin/node

      runHook postInstall
    '';

    meta = {
      description = "Node.js runtime for dsh (official upstream build)";
      homepage = "https://nodejs.org";
      license = lib.licenses.mit;
      mainProgram = "node";
      platforms = [ "x86_64-linux" ];
      sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
    };
  };

  runtimePnpm = pnpm_11.override { nodejs-slim = nodejs-slim_24; };

  # Electron desktop release metadata (see apps/desktop/src/host-protocol.ts).
  desktopProtocolVersion = 4;
in
stdenv.mkDerivation (finalAttrs: let
  # Primary runtime inputs pinned by the same source tree. `builtins.readFile`
  # on the fixed-output source path makes the lock available at evaluation
  # time, so wheel and interpreter URLs never need to be copied here.
  lock = builtins.fromJSON (builtins.readFile "${finalAttrs.src}/scripts/primary-runtime/lock.json");
  primaryTarget = "linux-x64";
  primaryLock = lock.targets.${primaryTarget};
  primaryPythonArchive = "cpython-${lock.pythonVersion}+${lock.pythonRelease}-${primaryLock.pythonTarget}-install_only_stripped.tar.gz";
  primaryNodeAsset = fetchurl {
    url = "https://nodejs.org/dist/v${lock.nodeVersion}/node-v${lock.nodeVersion}-${primaryLock.nodeArchive}";
    sha256 = primaryLock.nodeSha256;
  };
  primaryPythonAsset = fetchurl {
    url = "https://github.com/astral-sh/python-build-standalone/releases/download/${lock.pythonRelease}/${primaryPythonArchive}";
    sha256 = primaryLock.pythonSha256;
  };
  primaryWheelAssets = map (wheel: {
    inherit (wheel) sha256;
    asset = fetchurl {
      inherit (wheel) url sha256;
    };
  }) (primaryLock.wheels ++ lock.wheels);
in
{
  pname = "deepseek-harness";
  version = "0.1.7-rc.2";

  src = fetchFromGitHub {
    owner = "deepseek-ai";
    repo = "deepseek-harness";
    rev = "477b4f420553e8a52c2fbccc464d7561b239c443";
    hash = "sha256-bWeyipPsY5KclNGJPIttZ9CKRXCqkNIoKmK8VKN7FnI=";
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
    hash = "sha256-rDV6HxYwnPROBOP7/JY/cZ7kqmxv0zxOncjJghIvvM4=";
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
    makeWrapper
    nodejs_24
    patchelf
    pnpm_11
    pnpmConfigHook
    pnpmBuildHook
  ];

  postPatch = ''
    # Nixpkgs' static musl compiler replaces upstream's expected musl-gcc.
    substituteInPlace native/system/scripts/build.ts \
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

    # The primary-runtime staging directory contains the extracted Python
    # distribution's read-only directories, which Node's recursive rmSync
    # cannot unlink; GNU rm chmods them before removing.
    substituteInPlace scripts/primary-runtime/prepare.ts \
      --replace-fail \
        "rmSync(staging, { recursive: true, force: true })" \
        "execFileSync('rm', ['-rf', staging])"

    # Run the Desktop Host under the official Node runtime: its runtime-probing
    # addon (node-addon-require-builtin) does not recognize Electron's Node.
    substituteInPlace apps/desktop/src/main.ts \
      --replace-fail \
        "  const node = process.execPath" \
        "  const node = process.env.DSH_DESKTOP_NODE_EXECUTABLE ?? process.execPath"
  '';

  dontPatchShebangs = true;

  # The bundled Node and Python runtimes are patched by hand in installPhase;
  # the default strip/patchELF fixup pass corrupts the official Node binary.
  dontPatchELF = true;
  dontStrip = true;

  preBuild = ''
    # Source tarballs do not include .git; supply the pinned commit hash that
    # scripts/client-build-environment.ts embeds into client artifacts.
    export DSH_CLIENT_COMMIT_HASH=477b4f4
  '';

  postBuild = ''
    pnpm --dir native/system run build:native

    # Assemble the desktop primary runtime (upstream Node, Python, and Office
    # wheels) without network: the pinned fetchurl assets are pre-seeded into
    # the download cache the preparation script reads by sha256.
    primaryCache="$NIX_BUILD_TOP/dsh-primary-cache"
    primaryOut="$NIX_BUILD_TOP/dsh-primary-out"
    mkdir -p "$primaryCache" "$primaryOut"
    cp ${primaryNodeAsset} "$primaryCache/${primaryLock.nodeSha256}"
    cp ${primaryPythonAsset} "$primaryCache/${primaryLock.pythonSha256}"
    ${lib.concatMapStrings (wheel: ''
      cp ${wheel.asset} "$primaryCache/${wheel.sha256}"
    '') primaryWheelAssets}
    chmod u+w "$primaryCache"/*

    cat > prepare-primary-runtime.mjs <<'EOF'
    import { preparePrimaryRuntime } from './scripts/primary-runtime/prepare.ts'

    await preparePrimaryRuntime({
      target: 'linux-x64',
      output: process.argv[2],
      cache: process.argv[3],
      version: process.argv[4],
    })
    EOF
    ${lib.getExe nodejs_24} --import tsx/esm prepare-primary-runtime.mjs "$primaryOut" "$primaryCache" ${finalAttrs.version}
    rm -f prepare-primary-runtime.mjs prepare-primary-runtime.mjs.tsbuildinfo
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

    # --- Electron desktop client -------------------------------------------

    # The primary runtime lives beside its office-skills assets, and dsh's
    # desktop-host resolves pnpm/node-addon assets from the workspace root.
    mkdir -p $out/libexec/dsh-desktop
    cp -r "$NIX_BUILD_TOP/dsh-primary-out/primary-runtime" $out/libexec/dsh-desktop/primary-runtime
    cp -r "$NIX_BUILD_TOP/dsh-primary-out/office-skills" $out/libexec/dsh-desktop/office-skills

    # Upstream's prebuilt Node/Python expect a system loader; patch them for
    # the Nix store the same way runtimeNode is patched.
    chmod -R u+w $out/libexec/dsh-desktop
    runtimeLibPath="${lib.makeLibraryPath [ glibc stdenv.cc.cc.lib ]}"
    patchelf --set-interpreter ${stdenv.cc.bintools.dynamicLinker} \
      --set-rpath "$runtimeLibPath" \
      $out/libexec/dsh-desktop/primary-runtime/dependencies/node/bin/node
    # python, python3, and python3.12 are hardlinks in the archive; patchelf
    # replaces the file, breaking the link, so patch each name separately.
    for pythonBin in python python3 python3.12; do
      patchelf --set-interpreter ${stdenv.cc.bintools.dynamicLinker} \
        --add-rpath "$runtimeLibPath" \
        "$out/libexec/dsh-desktop/primary-runtime/dependencies/python/bin/$pythonBin"
    done

    # Release metadata the shell validates before starting the host: only the
    # two core packages are required at runtime, and the host runs under the
    # bundled Node runtime, not Electron's.
    LEAD_VERSION=${finalAttrs.version} \
    BUNDLED_NODE_VERSION=${nodeRuntimeVersion} \
    ${lib.getExe nodejs_24} - "$out" <<'NODE'
    const { readFileSync, writeFileSync } = require('node:fs')
    const out = process.argv[2]
    const version = process.env.LEAD_VERSION
    const pnpmVersion = JSON.parse(
      readFileSync(out + '/libexec/dsh/apps/desktop/node_modules/pnpm/package.json', 'utf8')).version
    const release = {
      schemaVersion: 1,
      version,
      hostProtocolVersion: ${toString desktopProtocolVersion},
      nodeVersion: process.env.BUNDLED_NODE_VERSION,
      pnpmVersion,
    }
    const sharedPackages = ['@deepseek-ai/dsh', '@deepseek-ai/dsh-desktop-host'].map((name) => ({
      name,
      version,
      path: 'node_modules/' + name,
    }))
    writeFileSync(out + '/libexec/dsh/desktop-runtime.json',
      JSON.stringify({ schemaVersion: 1, release, platform: 'linux', arch: 'x64', sharedPackages, files: [] }, null, 2) + '\n')
    NODE

    makeWrapper ${lib.getExe' electron_44 "electron"} $out/bin/dsh-desktop \
      --add-flags "$out/libexec/dsh/apps/desktop" \
      --set DSH_DESKTOP_DSH_DIR "$out/libexec/dsh" \
      --set DSH_DESKTOP_PRIMARY_RUNTIME_DIR "$out/libexec/dsh-desktop/primary-runtime" \
      --set DSH_DESKTOP_NODE_EXECUTABLE ${lib.getExe runtimeNode} \
      --prefix LD_LIBRARY_PATH : "${lib.makeLibraryPath [ glibc stdenv.cc.cc.lib zlib ]}"

    install -Dm644 $out/libexec/dsh/apps/desktop/resources/icon.png \
      $out/share/icons/hicolor/512x512/apps/dsh-desktop.png
    install -Dm644 $out/libexec/dsh/apps/desktop/resources/icon.png \
      $out/share/icons/hicolor/256x256/apps/dsh-desktop.png
    mkdir -p $out/share/applications
    cat > $out/share/applications/dsh-desktop.desktop <<'EOF'
    [Desktop Entry]
    Type=Application
    Name=DeepSeek Harness
    Comment=DeepSeek Harness AI agent desktop client
    Exec=dsh-desktop %U
    Icon=dsh-desktop
    Terminal=false
    Categories=Development;Utility;
    Keywords=DeepSeek;Harness;AI;Agent;
    EOF

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
    # The token URL answers with a 303 that mints the session cookie; the
    # index itself is then served from the clean root URL.
    WEB_URL="$webUrl" ${lib.getExe runtimeNode} <<'NODE'
    const root = new URL(process.env.WEB_URL);
    const landing = await fetch(root, { redirect: "manual" });
    const cookie = landing.headers.getSetCookie()[0]?.split(";")[0];
    if (landing.status !== 303 || cookie === undefined) process.exit(1);
    const response = await fetch(new URL("/", root), { headers: { cookie } });
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

    landlock="$app/native/system/packages/linux-x64/bin/landlock-run"
    test -x "$landlock"
    "$landlock" --probe | grep -Eq '^landlock: (fully|partially) enforced$'

    flockGlibc="$app/native/system/packages/linux-x64/bin/glibc/system.node"
    flockMusl="$app/native/system/packages/linux-x64/bin/musl/system.node"
    test -f "$flockGlibc" -a -f "$flockMusl"
    (cd "$app" && ${lib.getExe runtimeNode} --input-type=module <<'NODE'
    import { closeSync, mkdtempSync, openSync } from "node:fs";
    import { tmpdir } from "node:os";
    import { join } from "node:path";
    const { tryLockExclusive } = await import("@deepseek-ai/node-addon-system/flock");
    const dir = mkdtempSync(join(tmpdir(), "dsh-flock-"));
    const fd = openSync(join(dir, "lock"), "w");
    await tryLockExclusive(fd);
    closeSync(fd);
    NODE
    )

    if find "$app" -type l ! -exec test -e {} \; -print -quit | grep -q .; then
      find "$app" -type l ! -exec test -e {} \; -print >&2
      exit 1
    fi

    if grep -RIlE --exclude-dir=node_modules '/build/(source|tmp\.|\.home)' "$app"; then
      exit 1
    fi

    # --- Desktop client checks ---------------------------------------------

    desktop="$out/libexec/dsh-desktop"
    test -f "$app/desktop-runtime.json"
    test -x "$out/bin/dsh-desktop"
    test -f "$out/share/applications/dsh-desktop.desktop"
    test -f "$desktop/office-skills/scripts/check_office.py"

    # The patched bundled interpreters must run without nix-ld. The wheels need
    # libstdc++ and zlib, which the runtime Node would normally provide through
    # its DT_RPATH; a direct Python launch gets them from the library path.
    bundledNode="$desktop/primary-runtime/dependencies/node/bin/node"
    bundledPython="$desktop/primary-runtime/dependencies/python/bin/python3"
    "$bundledNode" -e 'process.exit(globalThis.process.versions.node ? 0 : 1)'
    LD_LIBRARY_PATH="${lib.makeLibraryPath [ glibc stdenv.cc.cc.lib zlib ]}" \
      "$bundledPython" -I -B -c 'import numpy, pandas, docx, pptx, openpyxl, lxml, PIL'
    "$bundledNode" "$desktop/primary-runtime/dependencies/pnpm/bin/pnpm.mjs" --version
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
