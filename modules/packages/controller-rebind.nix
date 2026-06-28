{pkgs, ...}: {
  environment.systemPackages = with pkgs; [
    (writeShellApplication {
      name = "controller-rebind";
      runtimeInputs = [ findutils gnugrep ];
      text = ''
        set -euo pipefail
        FLYDIGI_DEV="0003:04B4:2412.000C"
        JZ_DEV="0003:3151:4011.0005"
        BIND_PATH="/sys/bus/hid/drivers/hid-generic"

        flydigi_event=$(find "/sys/bus/hid/devices/$FLYDIGI_DEV/input" -maxdepth 2 -name "event[0-9]*" 2>/dev/null \
          | head -1 | grep -oP '\d+$' || echo "999")

        if [ "$flydigi_event" -le 31 ] 2>/dev/null; then
          echo "Flydigi APEX 4 is at event$flydigi_event (already in range), no rebind needed."
          exit 0
        fi

        echo "Flydigi APEX 4 is at event$flydigi_event, moving to low slot..."

        echo -n "$JZ_DEV" > "$BIND_PATH/unbind"
        sleep 0.2
        echo -n "$FLYDIGI_DEV" > "$BIND_PATH/unbind"
        sleep 0.2
        echo -n "$FLYDIGI_DEV" > "$BIND_PATH/bind"
        sleep 0.3
        echo -n "$JZ_DEV" > "$BIND_PATH/bind"
        sleep 0.3

        flydigi_event=$(find "/sys/bus/hid/devices/$FLYDIGI_DEV/input" -maxdepth 2 -name "event[0-9]*" 2>/dev/null \
          | head -1 | grep -oP '\d+$' || echo "???")
        echo "Done. Flydigi APEX 4 is now at /dev/input/event$flydigi_event"
      '';
    })
  ];
}
