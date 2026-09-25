{pkgs, ...}: let
  wechat-wrapped = pkgs.symlinkJoin {
    name = "wechat-wayland-fix";
    paths = [pkgs.wechat];
    buildInputs = [pkgs.makeWrapper];
    postBuild = ''
      wrapProgram $out/bin/wechat \
        --run 'ulimit -n 65536' \
        --set QT_QPA_PLATFORM xcb \
        --set XMODIFIERS "@im=fcitx" \
        --set QT_IM_MODULE fcitx

      rm $out/share/applications/*.desktop
      cp ${pkgs.wechat}/share/applications/*.desktop $out/share/applications/
      chmod +w $out/share/applications/*.desktop
      sed -i "s|^Exec=.*|Exec=$out/bin/wechat %U|" $out/share/applications/*.desktop
    '';
  };
in {
  # The /dev/nvidia* bwrap masks and the __NV_PRIME_RENDER_OFFLOAD /
  # __GLX_VENDOR_LIBRARY_NAME overrides that used to live here are gone:
  # Cardwire's eBPF LSM hook (modules/hardware/cardwire.nix) hides the dGPU
  # from every non-approved process, WeChat included.
  environment.systemPackages = [wechat-wrapped];
}
