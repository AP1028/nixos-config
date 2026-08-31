{ config, pkgs, ... }:
let
  username = config.local.username;
  helpers = ''
    CONSOLE_USER="${username}"
    CONSOLE_UID=$(id -u "$CONSOLE_USER" 2>/dev/null || id -u)

    # Talk to the console user's session bus regardless of how we're invoked.
    bus() {
      busctl --user --address="unix:path=/run/user/$CONSOLE_UID/bus" "$@"
    }
    as_user() {
      if [ "$(id -u)" -eq 0 ]; then
        sudo -u "$CONSOLE_USER" env XDG_RUNTIME_DIR="/run/user/$CONSOLE_UID" "$@"
      else
        "$@"
      fi
    }
    find_user_session() {
      for sid in $(loginctl list-sessions --no-legend 2>/dev/null | awk '$4 == "seat0" {print $1}'); do
        [ -n "$sid" ] || continue
        [ "$(loginctl show-session "$sid" -p Class --value 2>/dev/null)" = user ] || continue
        echo "$sid"
        return 0
      done
      return 1
    }
    proc_sid() {
      { tr '\0' '\n' < "/proc/$1/environ" || true; } 2>/dev/null | grep '^XDG_SESSION_ID=' | cut -d= -f2 || true
    }
    procs_of_console_user() {
      for p in /proc/[0-9]*; do
        [ "$(stat -c %u "$p" 2>/dev/null)" = "$CONSOLE_UID" ] || continue
        echo "''${p##*/}"
      done
    }
    proc_exe() {
      readlink "/proc/$1/exe" 2>/dev/null || true
    }
    # Kill every console-user process whose session is no longer in loginctl
    # (Plasma's systemd user units survive display-manager restarts and
    # collide with the next login). Silently skips non-readable processes.
    kill_dead_sessions() {
      LIVE=$(loginctl list-sessions --no-legend 2>/dev/null | awk '{print $1}' | tr '\n' ' ')
      for pid in $(procs_of_console_user); do
        sid=$(proc_sid "$pid")
        [ -n "$sid" ] || continue
        case " $LIVE " in *" $sid "*) continue ;; esac
        kill "$pid" 2>/dev/null || true
      done
      sleep 2
      for pid in $(procs_of_console_user); do
        sid=$(proc_sid "$pid")
        [ -n "$sid" ] || continue
        case " $LIVE " in *" $sid "*) continue ;; esac
        kill -9 "$pid" 2>/dev/null || true
      done
    }
    # True if the console user has a working desktop of the expected type:
    # active user session, matching compositor, plasmashell from that session,
    # and at least one panel on the bus.
    session_healthy() {
      SID=$(find_user_session || true)
      [ -n "$SID" ] || return 1
      [ "$(loginctl show-session "$SID" -p Name --value 2>/dev/null)" = "$CONSOLE_USER" ] || return 1
      [ "$(loginctl show-session "$SID" -p Active --value 2>/dev/null)" = yes ] || return 1
      [ "$(loginctl show-session "$SID" -p Type --value 2>/dev/null)" = "$1" ] || return 1

      KWIN=""
      for pid in $(procs_of_console_user); do
        [ "$(proc_sid "$pid")" = "$SID" ] || continue
        case "$(proc_exe "$pid")" in
          *kwin_wayland*) KWIN=wayland ;;
          *kwin_x11*) KWIN=x11 ;;
        esac
      done
      [ "$KWIN" = "$1" ] || return 1

      SHELL=""
      for pid in $(procs_of_console_user); do
        [ "$(proc_sid "$pid")" = "$SID" ] || continue
        case "$(proc_exe "$pid")" in
          *plasmashell*) SHELL=$pid ;;
        esac
      done
      [ -n "$SHELL" ] || return 1

      P=$(bus call --timeout=5 org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell evaluateScript s "print(panels().length)" 2>/dev/null || true)
      N=$(printf '%s' "$P" | awk -F'"' '{print $2}')
      [ -n "$N" ] && [ "$N" -gt 0 ] 2>/dev/null
    }
  '';
in {
  environment.systemPackages = [
    # Unified status: is the console user logged in on the graphical seat,
    # and in which session type (x11/wayland)? When not logged in, shows the
    # session the next boot would land in (merged SDDM conf, [Autologin]
    # preferred over [General] DefaultSession). Exit 0 = logged in, 1 = not.
    # The SDDM greeter session (class "greeter") is ignored — it is not a login.
    (pkgs.writeShellScriptBin "session-status" ''
      set -euo pipefail

      ${helpers}

      boot_session() {
        for f in /etc/sddm.conf.d/*.conf; do
          awk '
            /^\[/ { sec = $0; sub(/^\[/, "", sec); sub(/\]$/, "", sec); next }
            sec == "Autologin" && /Session=/ {
              a = substr($0, index($0, "=") + 1); gsub(/^[[:space:]]+|[[:space:]]+$/, "", a)
            }
            sec == "General" && /DefaultSession=/ {
              g = substr($0, index($0, "=") + 1); gsub(/^[[:space:]]+|[[:space:]]+$/, "", g)
            }
            END { print (a != "" ? a : g) }
          ' "$f" 2>/dev/null || true
        done | tail -1
      }

      session_type() {
        case "$1" in
          *x11*) echo x11 ;;
          *) echo wayland ;;
        esac
      }

      SID=$(find_user_session || true)
      if [ -z "$SID" ]; then
        SESSION=$(boot_session || true)
        [ -n "$SESSION" ] || SESSION=unknown
        echo "not logged in (greeter); boot session: $SESSION ($(session_type "$SESSION"))"
        exit 1
      fi
      if [ "$(loginctl show-session "$SID" -p Name --value 2>/dev/null)" != "$CONSOLE_USER" ]; then
        echo "session $SID is not for $CONSOLE_USER" >&2
        exit 1
      fi
      TYPE=$(loginctl show-session "$SID" -p Type --value 2>/dev/null)
      ACTIVE=$(loginctl show-session "$SID" -p Active --value 2>/dev/null)
      echo "logged in: session=$SID user=$CONSOLE_USER type=$TYPE active=$ACTIVE"
      [ "$ACTIVE" = yes ]
    '')

    # Headless desktop login via SSH. Usage:
    #   force-login [--force] [x11|wayland|session.desktop]   (default: wayland)
    # Health-aware: if a user session is up but the desktop is degraded
    # (wrong compositor, no plasmashell, no panels), it auto-recovers by
    # tearing everything down and logging in fresh.
    (pkgs.writeShellScriptBin "force-login" ''
      set -euo pipefail

      # Refuse to run as root: this script talks to the console user's session
      # and re-execs subcommands as that user; `sudo` is used internally only
      # for the specific privileged steps.
      if [ "$(id -u)" -eq 0 ]; then
        echo "error: run as your normal user, not root (sudo is handled internally)" >&2
        exit 1
      fi

      ${helpers}

      FORCE=0
      ARG=""
      for a in "$@"; do
        case "$a" in
          --force|-f) FORCE=1 ;;
          *) ARG="$a" ;;
        esac
      done
      ARG=''${ARG:-wayland}
      case "$ARG" in
        x11) SESSION="plasmax11.desktop"; EXPECTED=x11 ;;
        wayland) SESSION="plasma.desktop"; EXPECTED=wayland ;;
        *)
          SESSION="$ARG"
          case "$SESSION" in
            *x11*) EXPECTED=x11 ;;
            *) EXPECTED=wayland ;;
          esac
          ;;
      esac
      CONF="/etc/sddm.conf.d/99-force-login.conf"

      SID=$(find_user_session || true)
      CURRENT=""
      if [ -n "$SID" ]; then
        CURRENT=$(loginctl show-session "$SID" -p Type --value 2>/dev/null)
      fi
      if [ "$FORCE" != 1 ] && [ -n "$SID" ] && [ -n "$CURRENT" ] && [ "$CURRENT" = "$EXPECTED" ] && session_healthy "$EXPECTED"; then
        echo "already logged in (session $SID, type $EXPECTED), desktop healthy"
        exit 0
      fi
      if [ "$FORCE" != 1 ] && [ -n "$SID" ] && [ -n "$CURRENT" ] && [ "$CURRENT" = "$EXPECTED" ]; then
        echo "warning: session up but desktop degraded — tearing down and logging in fresh"
      fi
      [ -n "$SID" ] && echo "flipping session $SID ($CURRENT) -> $EXPECTED"

      if [ -n "$SID" ]; then
        echo "terminating session $SID and dead-session leftovers..."
        sudo loginctl terminate-session "$SID" || true
      else
        echo "cleaning up dead-session leftovers..."
      fi
      kill_dead_sessions || true
      echo "resetting plasma user units..."
      as_user systemctl --user stop 'plasma-*.service' 2>/dev/null || true
      # The systemd user manager (user@UID) outlives the graphical session
      # because lingering SSH/terminal sessions anchor it. startplasma-x11
      # imports DISPLAY / QT_QPA_PLATFORM=xcb / XDG_SESSION_TYPE=x11 into its
      # ManagerEnvironment via `systemctl --user import-environment`, and those
      # are never cleared. A later Wayland session's plasmashell is launched by
      # that same manager and inherits QT_QPA_PLATFORM=xcb, forcing it onto
      # XWayland and breaking its scene-graph (panels never render — "No
      # QSGTexture provided from updateSampledImage()"). Drop the stale session
      # vars so the next login re-imports a clean set.
      echo "clearing stale session environment from user manager..."
      as_user systemctl --user unset-environment DISPLAY XAUTHORITY QT_QPA_PLATFORM WAYLAND_DISPLAY XDG_SESSION_TYPE XDG_SESSION_ID XDG_SEAT_PATH XDG_SESSION_PATH XDG_SESSION_DESKTOP XDG_SESSION_CLASS XDG_CURRENT_DESKTOP 2>/dev/null || true
      # Flips can make kwin record duplicate outputs for one connector (garbled
      # EDID read during the mode switch), producing phantom screens that break
      # panel placement. Dedupe kwinoutputconfig.json (keep first per
      # connector) instead of deleting it, so scale/positions survive. The
      # kscreen profiles (which hold the enable/disable arrangement) are left
      # alone.
      echo "deduping output state..."
      CONSOLE_HOME=$(getent passwd "$CONSOLE_USER" | cut -d: -f6)
      python3 - "$CONSOLE_HOME/.config/kwinoutputconfig.json" << 'PYEOF' || true
import json
import sys
p = sys.argv[1]
try:
    with open(p) as f:
        d = json.load(f)
except Exception:
    sys.exit(0)
changed = False
for obj in d:
    if isinstance(obj, dict) and obj.get('name') == 'outputs' and isinstance(obj.get('data'), list):
        seen = set()
        new = []
        for e in obj['data']:
            if isinstance(e, dict) and e.get('connectorName') in seen:
                changed = True
                continue
            if isinstance(e, dict):
                seen.add(e.get('connectorName'))
            new.append(e)
        obj['data'] = new
if changed:
    with open(p, 'w') as f:
        json.dump(d, f)
PYEOF
      # Let the old X server fully die and the DP link settle before the new
      # compositor enumerates outputs.
      # The root-owned X server from a previous X11 session is NOT killed by
      # terminate-session (it belongs to SDDM, not the session scope) and keeps
      # holding /dev/dri/card1, so the new kwin fails eglInitialize and renders
      # QML scenes (panels) with a broken backend. The binary is named "X".
      # Kill it and wait until the DRM devices are actually released (only
      # counting holders that matter: X servers and the console user's dying
      # compositors — systemd/logind/the greeter legitimately hold card fds).
      sudo pkill -9 -x X 2>/dev/null || true
      sudo pkill -9 -x Xorg 2>/dev/null || true
      # Screen capture / streaming tools (Sunshine/Moonlight, OBS, screen
      # recorders, ffmpeg kmsgrab) grab /dev/dri/card* for KMS-plane capture and
      # VAAPI encode. If a stream is active during a flip, the next compositor
      # can't open the DRM device ("Device or resource busy") and the greeter
      # shows a black screen. Kill them (console-user only) so the device is
      # released before the new compositor starts.
      echo "killing screen-capture/streaming processes..."
      for pid in $(procs_of_console_user); do
        case "$(proc_exe "$pid")" in
          *sunshine*|*wl-screenrec*|*wf-recorder*|*/obs|*obs-studio*|*kmsgrab*|*ffmpeg*|*gnome-screencast*)
            kill "$pid" 2>/dev/null || true
            ;;
        esac
      done
      sleep 1
      for pid in $(procs_of_console_user); do
        case "$(proc_exe "$pid")" in
          *sunshine*|*wl-screenrec*|*wf-recorder*|*/obs|*obs-studio*|*kmsgrab*|*ffmpeg*|*gnome-screencast*)
            kill -9 "$pid" 2>/dev/null || true
            ;;
        esac
      done
      # Wait for the DRM devices to be released. Anything owned by the console
      # user that still holds a card (a dying compositor, or a capture tool that
      # ignored SIGTERM) is killed after a short grace period. systemd/logind
      # and the SDDM greeter (uid != CONSOLE_USER) legitimately hold card fds
      # and are left alone.
      echo "waiting for DRM devices to be released..."
      for i in $(seq 1 30); do
        BUSY=""
        for f in /proc/[0-9]*/fd/*; do
          tgt=$(readlink "$f" 2>/dev/null || true)
          case "$tgt" in
            */dri/card*)
              p=''${f#/proc/}
              p=''${p%%/*}
              comm=$(cat "/proc/$p/comm" 2>/dev/null || true)
              case "$comm" in
                X|Xorg)
                  BUSY="$BUSY ''${tgt##*/dri/}"
                  ;;
                *)
                  if [ "$(stat -c %u "/proc/$p" 2>/dev/null)" = "$CONSOLE_UID" ]; then
                    BUSY="$BUSY ''${tgt##*/dri/}"
                    if [ "$i" -ge 4 ]; then
                      echo "  killing $comm (pid $p) holding $tgt"
                      kill "$p" 2>/dev/null || true
                      [ "$i" -ge 8 ] && kill -9 "$p" 2>/dev/null || true
                    fi
                  fi
                  ;;
              esac
              ;;
          esac
        done
        BUSY=$(printf '%s' "$BUSY" | tr ' ' '\n' | sort -u | tr '\n' ' ')
        [ -z "$BUSY" ] && break
        [ $((i % 5)) = 0 ] && echo "  ...still held:$BUSY"
        sleep 1
      done
      [ -z "$BUSY" ] && echo "  DRM free" || echo "  warning: DRM still held:$BUSY"
      sleep 2

      printf '[Autologin]\nUser=%s\nSession=%s\n' "$CONSOLE_USER" "$SESSION" | sudo tee "$CONF" >/dev/null
      trap 'sudo rm -f "$CONF"' EXIT

      sudo systemctl restart display-manager
      echo "restarted display-manager, waiting for login..."

      SID=""
      for i in $(seq 1 45); do
        sleep 2
        SID=$(find_user_session || true)
        [ -n "$SID" ] || continue
        [ "$(loginctl show-session "$SID" -p Name --value 2>/dev/null)" = "$CONSOLE_USER" ] || continue
        [ "$(loginctl show-session "$SID" -p Active --value 2>/dev/null)" = yes ] || continue
        [ "$(loginctl show-session "$SID" -p Type --value 2>/dev/null)" = "$EXPECTED" ] || continue
        break
      done
      [ -n "$SID" ] || { echo "error: timeout waiting for $EXPECTED session" >&2; exit 1; }

      echo "session $SID up, waiting for desktop health..."
      HEALTHY=0
      for i in $(seq 1 30); do
        sleep 2
        if session_healthy "$EXPECTED"; then HEALTHY=1; break; fi
        [ $((i % 15)) = 0 ] && echo "...still waiting (''${i}x2s)"
      done

      if [ "$HEALTHY" != 1 ]; then
        echo "desktop degraded — restarting plasma-plasmashell.service..."
        as_user systemctl --user restart plasma-plasmashell.service 2>/dev/null || true
        for i in $(seq 1 15); do
          sleep 2
          if session_healthy "$EXPECTED"; then HEALTHY=1; break; fi
          [ $((i % 10)) = 0 ] && echo "...still waiting after shell restart"
        done
      fi

      if [ "$HEALTHY" = 1 ]; then
        as_user systemctl --user start plasma-kglobalaccel.service 2>/dev/null || true
        echo "logged in (session $SID, type $EXPECTED), desktop healthy"
        exit 0
      fi
      echo "error: session up but desktop still degraded — run session-debug" >&2
      exit 1
    '')

    # Flip the graphical session between X11 Plasma and Wayland Plasma without
    # rebuilding. Usage: flip-session [--force] x11|wayland
    (pkgs.writeShellScriptBin "flip-session" ''
      set -euo pipefail

      # Refuse to run as root (see force-login for rationale).
      if [ "$(id -u)" -eq 0 ]; then
        echo "error: run as your normal user, not root (sudo is handled internally)" >&2
        exit 1
      fi

      FORCE=0
      TARGET=""
      for a in "$@"; do
        case "$a" in
          --force|-f) FORCE=1 ;;
          x11|wayland) TARGET="$a" ;;
          *) echo "usage: flip-session [--force] x11|wayland" >&2; exit 1 ;;
        esac
      done
      [ -n "$TARGET" ] || { echo "usage: flip-session [--force] x11|wayland" >&2; exit 1; }

      echo "target: $TARGET"

      if [ "$TARGET" = x11 ] && ! grep -q '^\[X11\]' /etc/sddm.conf.d/00-nixos.conf; then
        echo "error: SDDM has no [X11] section (services.xserver.enable = false) — X11 is not available. Needs a rebuild first." >&2
        exit 1
      fi

      if [ "$FORCE" = 1 ]; then
        exec force-login --force "$TARGET"
      else
        exec force-login "$TARGET"
      fi
    '')

    # Full state dump for debugging a broken graphical session.
    (pkgs.writeShellScriptBin "session-debug" ''
      set -uo pipefail

      ${helpers}

      echo "== loginctl sessions =="
      loginctl list-sessions --no-legend 2>/dev/null || true
      SID=$(find_user_session || true)
      [ -n "$SID" ] && loginctl show-session "$SID" 2>/dev/null | grep -E "^Id=|^Name=|^Type=|^Class=|^Active=|^State=|^Seat=" || true

      echo "== console user graphical processes =="
      for pid in $(procs_of_console_user); do
        exe=$(proc_exe "$pid")
        case "$exe" in
          *kwin*|*plasma*|*shell*|*ksmserver*|*pipewire*|*portal*|*sddm*)
            cmd=$({ tr '\0' ' ' < "/proc/$pid/cmdline" || true; } 2>/dev/null)
            echo "pid=$pid sid=$(proc_sid "$pid") $cmd" | cut -c1-180
            ;;
        esac
      done

      echo "== bus owners =="
      bus list 2>/dev/null | grep -E "plasmashell|KWin|StatusNotifier|sddm|ksmserver" || echo "(no relevant bus owners — session bus unreachable)"

      echo "== panels =="
      bus call --timeout=5 org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell evaluateScript s "panels().length" 2>/dev/null || echo "plasmashell unresponsive"

      echo "== sddm conf =="
      for f in /etc/sddm.conf.d/*.conf; do
        echo "## $f"
        grep -E "Session|DefaultSession" "$f" 2>/dev/null || true
      done

      echo "== recent plasmashell crashes =="
      coredumpctl list --no-pager 2>/dev/null | grep -i plasmashell | tail -3 || echo "(none)"
    '')
  ];
}
