# DeepSeek Harness (dsh) — ported from nixpkgs PR #552467
# (https://github.com/NixOS/nixpkgs/pull/552467, commit 78c899151abde5b57684cb56a7851606ce39ab62).
#
# Approach: package the official npm distribution of @deepseek-ai/dsh instead
# of the GitHub source snapshot. The rc.6 tarball ships prebuilt lib/ code and
# prebuilt native artifacts (landlock-run per arch, node-pty build, koffi,
# sharp, node-addon-require-builtin); `buildNpmPackage` hermetically installs
# the production dependency closure from the checked-in package-lock.json with
# Node 24, and the binary runs on nodejs-slim_24 with pnpm on PATH (so
# `dsh plugin` profile management works from the store install).
#
# No corresponding source commit is claimed (upstream publishes the CLI on npm
# independently of its public source snapshot).
#
# Update notes: bump `version`, the fetchzip src hash (see PR diff for the
# registry URL form) and npmDepsHash. If npmDepsHash mismatches, build once
# with `npmDepsHash = lib.fakeHash` (or "" in older nixpkgs) and copy the
# reported store hash.

{
  buildNpmPackage,
  fetchzip,
  jq,
  lib,
  makeBinaryWrapper,
  nodejs_24,
  nodejs-slim_24,
  pnpm_11,
  stdenv,
  versionCheckHook,
}:

let
  runtimeNode = nodejs-slim_24;
  runtimePnpm = pnpm_11.override { nodejs-slim = runtimeNode; };
  landlockPackage =
    if stdenv.hostPlatform.isAarch64 then
      "node-addon-landlock-run-linux-arm64"
    else
      "node-addon-landlock-run-linux-x64";
in
buildNpmPackage (finalAttrs: {
  pname = "deepseek-harness";
  version = "0.1.0-rc.6";
  nodejs = nodejs_24;

  __structuredAttrs = true;

  src = fetchzip {
    url = "https://registry.npmjs.org/@deepseek-ai/dsh/-/dsh-${finalAttrs.version}.tgz";
    hash = "sha256-caYhF/Q3wBGCs6nW80RCEzWPF5eS3vs5kw7dyGjlLdo=";
  };

  npmDepsHash = "sha256-pi40Ksr3Kn7uLpUKQyiTi7XoSFg/1uTxFq1U/zGw/+s=";

  nativeBuildInputs = [ makeBinaryWrapper ];

  postPatch = ''
    ${lib.getExe jq} 'del(.devDependencies)' package.json > package.json.new
    mv package.json.new package.json
    # The rc.6 npm tarball does not ship a lockfile.
    cp ${./package-lock.json} package-lock.json
  '';

  dontNpmBuild = true;
  dontPatchShebangs = true;

  postInstall = ''
    app="$out/lib/node_modules/@deepseek-ai/dsh"

    rm -rf \
      "$app/node_modules/node-pty/deps" \
      "$app/node_modules/node-pty/node-addon-api" \
      "$app/node_modules/node-pty/prebuilds" \
      "$app/node_modules/node-pty/scripts" \
      "$app/node_modules/node-pty/src" \
      "$app/node_modules/node-pty/third_party" \
      "$app/node_modules/katex/src"

    find "$app/node_modules/node-pty/build" -type f \
      ! -path '*/Release/pty.node' -delete
    find "$app/node_modules/node-pty/build" -depth -type d -empty -delete

    while IFS= read -r file; do
      substituteInPlace "$file" \
        --replace-warn ${lib.getExe nodejs_24} ${lib.getExe runtimeNode}
    done < <(find "$app" -type f -exec grep -IlF ${lib.getExe nodejs_24} {} +)

    rm "$out/bin/dsh"
    makeBinaryWrapper ${lib.getExe runtimeNode} "$out/bin/dsh" \
      --add-flags "--expose-internals" \
      --add-flags "$app/lib/bin.js" \
      --prefix PATH : ${lib.makeBinPath [ runtimePnpm ]}
  '';

  doInstallCheck = true;

  nativeInstallCheckInputs = [ versionCheckHook ];

  versionCheckProgramArg = "--version";

  postInstallCheck = ''
    app="$out/lib/node_modules/@deepseek-ai/dsh"

    "$out/bin/dsh" --help > /dev/null
    DSH_HOME="$(mktemp -d)" \
      "$out/bin/dsh" --profile headless --dump-default-config > /dev/null
    DSH_HOME="$(mktemp -d)" \
      "$out/bin/dsh" plugin --profile install-check --version \
      | grep -Fx ${lib.escapeShellArg runtimePnpm.version}

    webLog="$(mktemp)"
    DSH_HOME="$(mktemp -d)" \
      "$out/bin/dsh" web --host 127.0.0.1 --port 0 > "$webLog" 2>&1 &
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

    APP="$app" ${lib.getExe runtimeNode} <<'NODE'
    const path = require("node:path");
    const pty = require(path.join(process.env.APP, "node_modules/node-pty"));
    require(path.join(process.env.APP, "node_modules/koffi"));
    require(path.join(process.env.APP, "node_modules/node-addon-require-builtin"));
    require(path.join(process.env.APP, "node_modules/sharp"));

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

    landlock="$app/node_modules/@deepseek-ai/${landlockPackage}/bin/landlock-run"
    test -x "$landlock"
    "$landlock" --probe | grep -Eq '^landlock: (fully|partially) enforced$'

    if find "$app" -xtype l -print -quit | grep -q .; then
      find "$app" -xtype l -print >&2
      exit 1
    fi

    if grep -RIlE '/build/(source|tmp\.|\.home)' "$out"; then
      exit 1
    fi
  '';

  meta = {
    description = "Open-source agent harness developed by DeepSeek AI";
    homepage = "https://github.com/deepseek-ai/deepseek-harness";
    downloadPage = "https://www.npmjs.com/package/@deepseek-ai/dsh";
    license = lib.licenses.mit;
    mainProgram = "dsh";
    platforms = [
      "aarch64-linux"
      "x86_64-linux"
    ];
    sourceProvenance = with lib.sourceTypes; [
      fromSource
      binaryNativeCode
    ];
  };
})
