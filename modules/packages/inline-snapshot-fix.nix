{lib, ...}: {
  # inline-snapshot 0.34.2's own doc-snapshot tests fail deterministically
  # against this nixpkgs' black (3/1402), which takes down every python
  # package listing it in checkInputs - on asusg16 that is
  # qemu -> ceph -> python3.12 env (narwhals -> sqlframe -> openai).
  # Same workaround as modules/services/comfyui.nix applies to its pinned
  # comfyui nixpkgs: skip the check phase. Scoped to 3.12 so the cache-hit
  # python3.14 chain (plasma) keeps its store paths.
  nixpkgs.overlays = [
    (final: prev: {
      pythonPackagesExtensions =
        prev.pythonPackagesExtensions
        ++ [
          (pyFinal: pyPrev:
            lib.optionalAttrs (pyPrev.python.pythonVersion == "3.12") {
              inline-snapshot = pyPrev.inline-snapshot.overridePythonAttrs (_: {
                doCheck = false;
              });
            })
        ];
    })
  ];
}
