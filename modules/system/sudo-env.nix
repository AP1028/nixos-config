{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.sudoEnv;

  kdialogBin = "${pkgs.kdePackages.kdialog}/bin/kdialog";

  askpassScript = pkgs.writeShellScript "desktop-askpass" ''
    if [ -x "${kdialogBin}" ]; then
      ${kdialogBin} --password "$1" 2>/dev/null
    else
      echo "Error: Graphical pinentry tool not found." >&2
      exit 1
    fi
  '';

  lockdir = "/run/sudo-env-lock";

  # Absolute paths keep the helper scripts working even under a minimal PATH
  # (and make the store dependencies explicit in the script closures).
  flockBin = "${pkgs.util-linux}/bin/flock";
  setsidBin = "${pkgs.util-linux}/bin/setsid";
  timeoutBin = "${pkgs.coreutils}/bin/timeout";

  fallbackFn = if cfg.headless
    then ''
      fallback() {
        [ -n "''${CATPID:-}" ] && kill "$CATPID" 2>/dev/null || true
        [ -n "''${REQDIR:-}" ] && rm -rf "$REQDIR" 2>/dev/null || true
        >&2 echo "[sudo-env] ''${1:-no sudo-lock daemon active}. Start it first: sudo-lock"
        exit 1
      }
    ''
    else ''
      fallback() {
        [ -n "''${CATPID:-}" ] && kill "$CATPID" 2>/dev/null || true
        [ -n "''${REQDIR:-}" ] && rm -rf "$REQDIR" 2>/dev/null || true
        export SUDO_ASKPASS="${askpassScript}"
        >&2 printf '[sudo-env] kdialog | %s\n' "$TRUNCATED"
        exec sudo --preserve-env -A -p "[sudo-env] $TRUNCATED" sh -c "$COMMAND"
      }
    '';
in {
  options.sudoEnv = {
    headless = lib.mkEnableOption ''
      headless mode: no graphical kdialog prompt; requires the sudo-lock
      daemon to be running (falls back to an error if it is not)
    '';
  };

  config = {
    systemd.tmpfiles.rules = [
      "d ${lockdir} 0755 root root -"
    ];

    environment.systemPackages = [
      (pkgs.writeShellScriptBin "sudo-env" ''
        set -u

        if [ "''${1:-}" != "-c" ] || [ -z "''${2:-}" ]; then
          echo "Usage: sudo-env -c 'your-escalated-command'" >&2
          exit 1
        fi

        shift
        COMMAND="$*"
        TRUNCATED=$(printf '%s' "$COMMAND" | head -c 80)
        [ "$TRUNCATED" != "$COMMAND" ] && TRUNCATED="$TRUNCATED..."

        LOCKFILE="${lockdir}/$UID"
        CMDFIFO="${lockdir}/$UID.cmd"
        REQBASE="${lockdir}/$UID.requests"

        ${fallbackFn}

        daemon_alive() {
          local pid
          [ -f "$LOCKFILE" ] || return 1
          pid=$(cat "$LOCKFILE" 2>/dev/null) || return 1
          case "$pid" in
            '''|*[!0-9]*) return 1 ;;
          esac
          [ -d "/proc/$pid" ] || return 1
          grep -q '^sudo-lock$' "/proc/$pid/comm" 2>/dev/null || return 1
          [ -p "$CMDFIFO" ] || return 1
          [ -d "$REQBASE" ] || return 1
          [ -w "$REQBASE" ] || return 1
        }

        if ! daemon_alive; then
          fallback "no sudo-lock daemon active"
        fi

        LOCKPID=$(cat "$LOCKFILE" 2>/dev/null)
        >&2 printf '[sudo-env] daemon PID %s | %s\n' "$LOCKPID" "$TRUNCATED"

        # Every request gets its own output FIFO. sudo-lock only ever forks a
        # worker that redirects the command's stdout/stderr into this FIFO, so
        # the daemon loop itself can never be blocked by a command.
        umask 077
        REQDIR=""
        REQDIR=$(mktemp -d "$REQBASE/req.XXXXXX") || fallback "cannot create request directory"
        TOKEN=$(basename "$REQDIR")
        OUTFIFO="$REQDIR/out"
        ACKFILE="$REQDIR/ack"
        STATUSFILE="$REQDIR/status"

        cleanup() {
          if [ -n "''${CATPID:-}" ]; then
            kill "$CATPID" 2>/dev/null || true
          fi
          [ -n "''${REQDIR:-}" ] && rm -rf "$REQDIR" 2>/dev/null || true
        }
        trap cleanup EXIT
        trap 'cleanup; exit 130' HUP INT TERM

        mkfifo "$OUTFIFO" || { fallback "cannot create output fifo"; }
        chmod 600 "$OUTFIFO"

        # Open the read end in the background *before* sending the request.
        # The daemon worker opens the write end, so a very fast command
        # cannot finish and close the FIFO before we have a reader attached
        # (which would drop all buffered output). If this client dies, the
        # worker gets SIGPIPE on its next write instead of hanging forever.
        CATPID=""
        cat "$OUTFIFO" &
        CATPID=$!

        PAYLOAD=$(printf '%s\t%s' \
          "$TOKEN" \
          "$(printf '%s' "$COMMAND" | base64 -w0)")

        # Bounded delivery handshake only (no command timeout): if the daemon
        # died between the liveness check above and now, do not let sudo-env
        # hang on the command FIFO forever.
        if printf '%s\n' "$PAYLOAD" | ${timeoutBin} 15 cat > "$CMDFIFO"; then
          :
        else
          >&2 echo "[sudo-env] warning: timed out delivering command to sudo-lock"
        fi

        # The daemon acknowledges by creating the ack file before the command
        # starts. Without the ack we know the command was never accepted and
        # falling back cannot execute it twice.
        wait_for_ack() {
          local i=0
          while [ "$i" -lt 150 ]; do
            [ -s "$ACKFILE" ] && return 0
            sleep 0.1
            i=$((i + 1))
          done
          return 1
        }

        if ! wait_for_ack; then
          >&2 echo "[sudo-env] sudo-lock did not acknowledge the command"
          fallback "sudo-lock did not acknowledge the command"
        fi

        # Command output is streamed to this client's stdout by the
        # background cat. Its exit status only reflects delivery; the real
        # command status is read from the status file below.
        wait "$CATPID"
        CATPID=""

        if [ -f "$STATUSFILE" ]; then
          STATUS=$(cat "$STATUSFILE" 2>/dev/null || true)
        else
          STATUS=255
        fi
        case "$STATUS" in
          '''|*[!0-9]*) STATUS=255 ;;
        esac
        exit "$STATUS"
      '')

      (pkgs.writeShellScriptBin "sudo-lock" ''
        # No `set -e` here on purpose: the daemon must survive any worker or
        # command failure and only exit through cleanup.
        umask 077

        if [ "$(id -u)" -ne 0 ]; then
          echo "[sudo-lock] not root, re-invoking via sudo..." >&2
          exec sudo "$0" "$@"
        fi

        if [ -z "''${SUDO_USER:-}" ]; then
          echo "sudo-lock: SUDO_USER not set. Run via sudo-env." >&2
          exit 1
        fi

        LOCKFILE="${lockdir}/$SUDO_UID"
        CMDFIFO="${lockdir}/$SUDO_UID.cmd"
        OUTFIFO_LEGACY="${lockdir}/$SUDO_UID.out"
        REQBASE="${lockdir}/$SUDO_UID.requests"
        GROUP="''${SUDO_GID:-$SUDO_UID}"

        # Auto-detach: if not a terminal, re-launch with nohup to survive parent.
        # `--clean` stays synchronous even when stdin is not a terminal.
        if [ ! -t 0 ] && [ "''${1:-}" != "--fg" ] && [ "''${1:-}" != "--clean" ]; then
          LOGFILE="/tmp/sudo-lock-$SUDO_UID.log"
          mkdir -p "${lockdir}"
          chmod 0755 "${lockdir}"
          nohup "$0" --fg "$@" < /dev/null >> "$LOGFILE" 2>&1 &
          chmod 644 "$LOGFILE" 2>/dev/null || true
          echo "sudo-lock: detached (PID $!). Output -> $LOGFILE"
          exit 0
        fi

        mkdir -p "${lockdir}"
        chmod 0755 "${lockdir}"

        if [ "''${1:-}" = "--clean" ]; then
          # flock makes the stale check race-free: only one cleaner/daemon can
          # hold the lock at a time.
          exec 9>>"$LOCKFILE"
          if ! ${flockBin} -n 9; then
            LOCKPID=$(cat "$LOCKFILE" 2>/dev/null || true)
            echo "sudo-lock: lock is active (PID ''${LOCKPID:-unknown}). Kill it first or press Ctrl+C in its terminal." >&2
            exit 1
          fi
          rm -f "$LOCKFILE" "$CMDFIFO" "$OUTFIFO_LEGACY"
          rm -rf "$REQBASE"
          echo "sudo-lock: cleaned lock for $SUDO_USER."
          exit 0
        fi

        # Race-free single-instance startup. The lockfile itself is the old
        # `${lockdir}/$UID` file, so client liveness checks keep working.
        exec 9>>"$LOCKFILE"
        if ! ${flockBin} -n 9; then
          LOCKPID=$(cat "$LOCKFILE" 2>/dev/null || true)
          echo "sudo-lock: already active (PID ''${LOCKPID:-unknown})." >&2
          exit 1
        fi

        mkdir -p "$REQBASE"
        chown "$SUDO_UID":"$GROUP" "$REQBASE"
        chmod 700 "$REQBASE"

        rm -f "$CMDFIFO" "$OUTFIFO_LEGACY"
        mkfifo "$CMDFIFO" || { echo "sudo-lock: failed to create FIFO" >&2; exit 1; }
        chown "$SUDO_UID":"$GROUP" "$CMDFIFO"
        chmod 600 "$CMDFIFO"

        cleanup() {
          trap - EXIT HUP INT TERM
          # Kill every worker session (workers are setsid'd, so the process
          # group id equals the worker pid). This matches the old foreground
          # behaviour where Ctrl+C also killed the running command.
          for job in $(jobs -pr); do
            kill -TERM -- "-$job" 2>/dev/null || kill -TERM "$job" 2>/dev/null || true
          done
          if [ -f "$LOCKFILE" ] && [ "$(cat "$LOCKFILE" 2>/dev/null)" = "$$" ]; then
            rm -f "$LOCKFILE"
          fi
          rm -f "$CMDFIFO" "$OUTFIFO_LEGACY"
          echo ""
          echo "sudo-lock released."
          exit 0
        }
        trap cleanup EXIT HUP INT TERM

        # Open the command FIFO read-write so the daemon can poll it with a
        # read timeout and never blocks opening it. Only publish the PID
        # after the reader is attached: clients check the lockfile and may
        # start writing immediately.
        exec 3<> "$CMDFIFO"
        printf '%s\n' "$$" > "$LOCKFILE"
        chmod 644 "$LOCKFILE"

        handle_request() {
          encoded=$1

          IFS=$'\t' read -r TOKEN PAYLOAD <<< "$encoded"
          case "$TOKEN" in
            '''|*[!a-zA-Z0-9_.-]*) return ;;
          esac

          CMD=$(printf '%s' "$PAYLOAD" | base64 -d 2>/dev/null || true)
          [ -n "$CMD" ] || return

          REQDIR="$REQBASE/$TOKEN"
          OUTFIFO="$REQDIR/out"
          STATUSFILE="$REQDIR/status"
          ACKFILE="$REQDIR/ack"
          if [ ! -d "$REQDIR" ] || [ ! -p "$OUTFIFO" ]; then
            echo "[sudo-lock] request $TOKEN has no output fifo, dropping" >&2
            return
          fi

          CMD_TAIL=$(printf '%s' "$CMD" | head -c 80)
          echo "[sudo-lock] exec ($TOKEN): $CMD_TAIL"

          # Worker per request. The daemon loop keeps accepting new requests
          # while the command runs; the command's stdout/stderr go straight to
          # the requesting client's private FIFO, so a hung/interactive command
          # can only ever block its own worker, never sudo-lock. Commands run
          # with stdin=/dev/null and no controlling terminal, which makes ssh
          # host-key/password prompts fail immediately instead of wedging the
          # daemon. No timeout is imposed here: callers own command deadlines.
          ${setsidBin} bash -c '
            out=$1
            status=$2
            ack=$3
            command=$4
            token=$5

            # Never leak the daemon lock fd (9) or command FIFO fd (3) into
            # a command: otherwise an orphaned worker could keep the startup
            # lock held and commands could write back into the request FIFO.
            exec 3>&- 2>/dev/null || true
            exec 9>&- 2>/dev/null || true

            echo "$$" > "$ack" 2>/dev/null || exit 127
            # These files are created by root inside the requesting users
            # private 0700 directory; make them readable so the client can
            # consume the status after the output stream ends.
            chmod 644 "$ack" 2>/dev/null || true
            # The client already opened the read end before sending, so this
            # normally completes immediately. Write-only also means a vanished
            # client produces SIGPIPE rather than a permanently blocked worker.
            exec 4> "$out" || { echo 126 > "$status" 2>/dev/null; chmod 644 "$status" 2>/dev/null || true; exit 126; }

            sh -c "$command" < /dev/null >&4 2>&4
            rc=$?

            echo "$rc" > "$status" 2>/dev/null || true
            chmod 644 "$status" 2>/dev/null || true
            exec 4>&- 2>/dev/null || true
            echo "[sudo-lock] done ($token) rc=$rc" >&2
            exit 0
          ' bash "$OUTFIFO" "$STATUSFILE" "$ACKFILE" "$CMD" "$TOKEN" &
        }

        echo "sudo-lock active for $SUDO_USER (PID $$). Press Ctrl+C to release."

        while :; do
          if read -r -t 5 -u 3 encoded 2>/dev/null && [ -n "$encoded" ]; then
            handle_request "$encoded"
          fi

          # Recreate the request directory if a client (or a cleanup) removed it.
          if [ ! -d "$REQBASE" ]; then
            mkdir -p "$REQBASE"
            chown "$SUDO_UID":"$GROUP" "$REQBASE"
            chmod 700 "$REQBASE"
          fi

          if [ ! -e "/proc/$$/fd/3" ]; then
            echo "[sudo-lock] fd 3 lost, reopening..." >&2
            exec 3<> "$CMDFIFO"
          fi

          # Refresh the user's sudo timestamp in the idle loop.
          sudo -n -u "$SUDO_USER" -v 2>/dev/null || true
        done
      '')
    ];
  };
}
