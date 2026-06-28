{
  config,
  pkgs,
  ...
}: let
  game-env = pkgs.buildFHSEnv {
    name = "game-env";
    targetPkgs = pkgs: with pkgs; [
      # ── Core system ──
      bash
      coreutils
      glibc
      zlib
      stdenv.cc.cc.lib
      util-linux

      # ── Graphics ──
      libglvnd
      mesa
      libdrm
      vulkan-loader
      vulkan-validation-layers
      libGL
      libGLU
      libgbm
      egl-wayland

      # ── X11 ──
      libX11
      libXext
      libXrender
      libXrandr
      libXcursor
      libXfixes
      libXxf86vm
      libXi
      libXinerama
      libXcomposite
      libXdamage
      libXScrnSaver
      libxcb
      libxshmfence
      xcbutilkeysyms
      xcbutilimage
      xcbutilwm
      xcbutilrenderutil

      # ── Wayland ──
      wayland
      wayland-protocols
      libxkbcommon

      # ── Audio ──
      alsa-lib
      pulseaudio
      pipewire
      libpulseaudio
      openal
      libsndfile

      # ── Input ──
      libinput
      udev
      libusb1

      # ── Fonts & text ──
      fontconfig
      freetype
      pango
      cairo
      harfbuzz
      fribidi

      # ── UI toolkits ──
      gtk2
      gtk3
      glib
      gdk-pixbuf
      atk
      qt5.qtbase
      qt5.qtx11extras

      # ── Game runtimes & helpers ──
      SDL2
      SDL2_image
      SDL2_mixer
      SDL2_ttf
      SDL2_net
      libogg
      libvorbis
      flac
      libpng
      libjpeg
      libwebp
      giflib
      libGLU

      # ── Networking ──
      openssl
      curl
      glib-networking
      gnutls

      # ── Misc ──
      dbus
      expat
      nss
      nspr
      cups
      libsecret
      bzip2
      xz
      libgcrypt
      libgpg-error
      systemd
      libcap
      lz4
      libunwind
      elfutils
    ];

    multiPkgs = pkgs: with pkgs; [
      glibc
      zlib
      libglvnd
      libGL
      stdenv.cc.cc.lib
      libX11
      libXext
      libXrender
      libXcursor
      libXfixes
      libXi
      libxcb
      alsa-lib
      libpulseaudio
      pipewire
      cups
      nss
      nspr
      fontconfig
      freetype
      expat
      systemd
    ];

    extraBindMounts = {
      "/run/opengl-driver" = "/run/opengl-driver";
      "/run/opengl-driver-32" = "/run/opengl-driver-32";
    };

    profile = ''
      export IN_FHS_ENV="game-env"
      export __GLX_VENDOR_LIBRARY_NAME=mesa
      export LIBGL_DRIVERS_PATH="/run/opengl-driver/lib/dri:/run/opengl-driver-32/lib/dri"
      if [ -d /run/opengl-driver/share/glvnd/egl_vendor.d ]; then
        export __EGL_VENDOR_LIBRARY_DIRS="/run/opengl-driver/share/glvnd/egl_vendor.d"
        export __GLX_VENDOR_LIBRARY_DIRS="/run/opengl-driver/share/glvnd/glx_vendor.d"
      fi
      export LD_LIBRARY_PATH="/run/opengl-driver/lib:/run/opengl-driver-32/lib:/lib:/usr/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    '';

    runScript = "zsh";
  };
in {
  environment.systemPackages = [game-env];
}
