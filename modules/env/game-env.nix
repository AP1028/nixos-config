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
      libICE
      libSM
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

      # ── Accessibility (CEF/chromium) ──
      at-spi2-core
      at-spi2-atk
      atk
      webkitgtk_4_1
      libavif
      dav1d

      # ── Runtimes ──
      dotnet-runtime_9

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
      xdg-utils
      xscreensaver
      libkrb5
      keyutils
      libbsd
      libmd
      libuuid
      icu
      openldap
      avahi
      libepoxy
      graphene
      json-glib
      libpsl
      libsoup_3
      re2
      snappy
      minizip
      brotli
      libffi
      libtasn1
      p11-kit
      sqlite
      libdecor
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
