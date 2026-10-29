{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.headlessVirtualDesktop;

  krfb = pkgs.kdePackages.krfb;
  kscreen = pkgs.kdePackages.libkscreen;
  kwriteconfig = pkgs.kdePackages.kconfig;
  jq = pkgs.jq;

  vkmsDevice = "/dev/dri/vkms";
  renderDevice = lib.replaceStrings [":"] ["\\:"] cfg.renderDevice;

  obscurePassword = pkgs.writeText "obscure-vnc-password.py" ''
    import sys
    print("".join(chr(0x1001F - ord(c)) if ord(c) > 0x21 else c for c in sys.stdin.read().strip()), end="")
  '';

  prepareKrfb = pkgs.writeShellScript "headless-vnc-setup" ''
    set -eu
    ${
      if cfg.vnc.passwordFile == null
      then ''pwfile="$HOME/.config/headless-virtual-desktop/vnc-password"''
      else "pwfile=${lib.escapeShellArg (toString cfg.vnc.passwordFile)}"
    }
    ${
      lib.optionalString (cfg.vnc.passwordFile == null) ''
        if [ ! -s "$pwfile" ]; then
          mkdir -p "$(dirname "$pwfile")"
          (umask 077; ${pkgs.openssl}/bin/openssl rand -hex 4 > "$pwfile")
        fi
      ''
    }
    password=$(cat "$pwfile")
    obscured=$(${pkgs.python3}/bin/python3 ${obscurePassword} <<<"$password")

    ${kwriteconfig}/bin/kwriteconfig6 --file krfbrc --group MainWindow --key startMinimized true
    ${kwriteconfig}/bin/kwriteconfig6 --file krfbrc --group TCP --key useDefaultPort true
    ${kwriteconfig}/bin/kwriteconfig6 --file krfbrc --group TCP --key port ${toString cfg.vnc.port}
    ${kwriteconfig}/bin/kwriteconfig6 --file krfbrc --group Security --key noWallet true
    ${kwriteconfig}/bin/kwriteconfig6 --file krfbrc --group Security --key allowDesktopControl true
    ${kwriteconfig}/bin/kwriteconfig6 --file krfbrc --group Security --key allowUnattendedAccess true
    ${kwriteconfig}/bin/kwriteconfig6 --file krfbrc --group Security --key unattendedPassword "$obscured"
    ${kwriteconfig}/bin/kwriteconfig6 --file krfbrc --group Security --key desktopPassword "$obscured"
    ${kwriteconfig}/bin/kwriteconfig6 --file krfbrc --group FrameBuffer --key preferredFrameBufferPlugin pw

    for app in "" "org.kde.krfb"; do
      ${pkgs.glib}/bin/gdbus call --session \
        --dest org.freedesktop.impl.portal.PermissionStore \
        --object-path /org/freedesktop/impl/portal/PermissionStore \
        --method org.freedesktop.impl.portal.PermissionStore.SetPermission \
        kde-authorized true remote-desktop "$app" "['yes']" >/dev/null || true
    done
  '';

  setupOutputs = pkgs.writeShellScript "headless-virtual-desktop-setup" ''
    set -eu
    resolution=${lib.escapeShellArg cfg.resolution}
    width=${lib.head (lib.splitString "x" cfg.resolution)}
    height=${lib.last (lib.splitString "x" cfg.resolution)}
    refresh=${toString cfg.refreshRate}

    for _ in $(${pkgs.coreutils}/bin/seq 1 60); do
      if ${kscreen}/bin/kscreen-doctor -j 2>/dev/null |
        ${jq}/bin/jq -e '.outputs[] | select(.connected)' >/dev/null; then
        break
      fi
      ${pkgs.coreutils}/bin/sleep 0.5
    done

    name=$(${kscreen}/bin/kscreen-doctor -j |
      ${jq}/bin/jq -r '[.outputs[] | select(.connected and (.name | startswith("Virtual-")))][0].name // ([.outputs[] | select(.connected)][0].name) // empty')
    if [ -z "$name" ]; then
      echo "no connected virtual output found" >&2
      exit 1
    fi

    ${kscreen}/bin/kscreen-doctor "output.$name.enable" || true
    result=$(${kscreen}/bin/kscreen-doctor "output.$name.mode.$resolution@$refresh" 2>&1) || true
    if printf '%s' "$result" | ${pkgs.gnugrep}/bin/grep -qi 'not found'; then
      ${kscreen}/bin/kscreen-doctor "output.$name.addCustomMode.$width.$height.$((refresh * 1000)).full" || true
      ${kscreen}/bin/kscreen-doctor "output.$name.mode.$resolution@$refresh"
    fi
    ${kscreen}/bin/kscreen-doctor "output.$name.primary"
  '';
in {
  imports = [./plasma.nix];

  options.services.headlessVirtualDesktop = {
    enable = lib.mkEnableOption "a GPU-rendered headless Plasma Wayland desktop on vkms";

    user = lib.mkOption {
      type = lib.types.str;
      default = config.local.username;
      description = "User that owns the graphical session and the VNC server.";
    };

    renderDevice = lib.mkOption {
      type = lib.types.str;
      example = "/dev/dri/gpu0";
      description = ''
        DRM card node used for rendering, as the first entry of
        KWIN_DRM_DEVICES. Use a stable symlink without colons in the path;
        KWIN_DRM_DEVICES treats colons as separators.
      '';
    };

    resolution = lib.mkOption {
      type = lib.types.strMatching "[0-9]+x[0-9]+";
      default = "1920x1080";
      description = "Resolution of the vkms virtual output.";
    };

    refreshRate = lib.mkOption {
      type = lib.types.int;
      default = 60;
      description = "Refresh rate of the vkms virtual output.";
    };

    vnc = {
      port = lib.mkOption {
        type = lib.types.port;
        default = 5900;
        description = "RFB/VNC port served by krfb.";
      };

      passwordFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = ''
          File containing the VNC password, readable by the desktop user. When
          null, an 8-character password is generated on first start and stored
          in ~/.config/headless-virtual-desktop/vnc-password.
        '';
      };
    };

    sunshine.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Configure Sunshine to capture the vkms output with the KWin backend.";
    };
  };

  config = lib.mkIf cfg.enable {
    boot.kernelModules = ["vkms"];
    boot.extraModprobeConfig = "options vkms enable_cursor=1";

    services.udev.extraRules = ''
      SUBSYSTEM=="drm", KERNEL=="card[0-9]*", DEVPATH=="/devices/faux/vkms/drm/card[0-9]*", SYMLINK+="dri/vkms"
    '';

    environment.sessionVariables = {
      KWIN_DRM_DEVICES = "${renderDevice}:${vkmsDevice}";
      KWIN_FORCE_SW_CURSOR = "1";
    };

    services.displayManager.autoLogin = {
      enable = true;
      user = cfg.user;
    };

    environment.systemPackages =
      [
        krfb
        kscreen
        kwriteconfig
        pkgs.python3
      ]
      ++ lib.optional (cfg.sunshine.enable && config.services.sunshine.enable) (
        pkgs.writeTextDir "share/applications/dev.lizardbyte.app.Sunshine.kwin.desktop" ''
          [Desktop Entry]
          Type=Application
          Name=Sunshine KWin screencast permission
          NoDisplay=true
          Exec=${lib.getExe config.services.sunshine.package}
          X-KDE-Wayland-Interfaces=zkde_screencast_unstable_v1
        ''
      );

    networking.firewall.allowedTCPPorts = [cfg.vnc.port];

    systemd.user.services.headless-virtual-desktop-setup = {
      description = "Set the vkms output mode for the headless desktop";
      wantedBy = ["plasma-workspace.target"];
      partOf = ["plasma-workspace.target"];
      after = ["plasma-workspace.target" "plasma-kwin_wayland.service"];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = setupOutputs;
        RemainAfterExit = true;
      };
    };

    systemd.user.services.plasma-xdg-desktop-portal-kde = {
      overrideStrategy = "asDropin";
      wants = ["xdg-permission-store.service"];
      after = ["xdg-permission-store.service"];
    };

    systemd.user.services."app-org.kde.krfb" = {
      description = "KDE desktop sharing (VNC) for the headless virtual desktop";
      wantedBy = ["plasma-workspace.target"];
      partOf = ["plasma-workspace.target"];
      wants = [
        "plasma-xdg-desktop-portal-kde.service"
        "xdg-desktop-portal.service"
        "xdg-permission-store.service"
      ];
      after = [
        "plasma-workspace.target"
        "plasma-xdg-desktop-portal-kde.service"
        "xdg-desktop-portal.service"
        "xdg-permission-store.service"
        "headless-virtual-desktop-setup.service"
      ];
      serviceConfig = {
        Type = "simple";
        ExecStartPre = prepareKrfb;
        ExecStart = "${krfb}/bin/krfb --nodialog";
        Restart = "on-failure";
        RestartSec = 3;
        Environment = ["QT_QPA_PLATFORM=wayland"];
      };
    };

    services.sunshine.settings = lib.mkIf cfg.sunshine.enable {
      capture = "kwin";
      system_tray = "0";
      ping_timeout = "30000";
    };

    systemd.user.services.sunshine = lib.mkIf (cfg.sunshine.enable && config.services.sunshine.enable) {
      wants = ["plasma-workspace.target"];
      after = ["plasma-workspace.target"];
    };
  };
}
