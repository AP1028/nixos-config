{...}: {
  nixpkgs.overlays = [(final: prev: {
    electron = prev.electron.overrideAttrs (old: {
      nativeBuildInputs = (old.nativeBuildInputs or []) ++ [prev.bubblewrap];
      buildCommand = (old.buildCommand or "") + ''
        sed -i 's|^exec \(".*electron-unwrapped[^"]*/libexec/electron/electron"\)\(.*\)|exec ${prev.bubblewrap}/bin/bwrap --dev-bind / / --dev-bind /dev/null /dev/nvidia0 --dev-bind /dev/null /dev/nvidiactl --dev-bind /dev/null /dev/nvidia-modeset --dev-bind /dev/null /dev/nvidia-uvm --dev-bind /dev/null /dev/nvidia-uvm-tools \1\2|' $out/bin/electron
      '';
    });
  })];
}
