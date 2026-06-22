{pkgs, ...}: let
  wechat-wrapped = pkgs.symlinkJoin {
    name = "wechat-wayland-fix";
    paths = [pkgs.wechat];
    buildInputs = [pkgs.makeWrapper];
    postBuild = ''
      wrapProgram $out/bin/wechat \
        --set QT_QPA_PLATFORM xcb \
        --set XMODIFIERS "@im=fcitx" \
        --set QT_IM_MODULE fcitx \
        --set __NV_PRIME_RENDER_OFFLOAD 0 \
        --set __GLX_VENDOR_LIBRARY_NAME mesa

      rm -f $out/bin/.wechat-wrapped
      cp ${pkgs.wechat}/bin/wechat $out/bin/.wechat-wrapped
      chmod +w $out/bin/.wechat-wrapped
      ${pkgs.gnused}/bin/sed -i '/^  --dev-bind \/dev \/dev$/a\
  --dev-bind /dev/null /dev/nvidia0 \
  --dev-bind /dev/null /dev/nvidiactl \
  --dev-bind /dev/null /dev/nvidia-modeset \
  --dev-bind /dev/null /dev/nvidia-uvm \
  --dev-bind /dev/null /dev/nvidia-uvm-tools' $out/bin/.wechat-wrapped

      rm $out/share/applications/*.desktop
      cp ${pkgs.wechat}/share/applications/*.desktop $out/share/applications/
      chmod +w $out/share/applications/*.desktop
      sed -i "s|^Exec=.*|Exec=$out/bin/wechat %U|" $out/share/applications/*.desktop
    '';
  };
in {
  environment.systemPackages = [wechat-wrapped];
}
