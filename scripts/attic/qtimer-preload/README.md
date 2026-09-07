# qtimer-preload — find long blocking polls in Cadence Qt tools under FEX

An x86_64 `LD_PRELOAD` interposer. It intercepts `ppoll()` (and the Qt
`QTimer`/`QObject::startTimer` entry points) and, when a poll timeout is
`>= 20s`, appends a raw backtrace to `$QTIMER_LOG`. It was used to pin the
~135s virtuoso launch stall down to `QCadenceStyle::cdsRoot()` →
`QProcess::waitForStarted/Finished(30000)`.

## Build

```
nix build --impure --expr \
  "(import /home/tianyixia/nixos-config/scripts/qtimer-preload/build.nix)" -o result
cp result/qtimer_preload.so ~/.cadence/qtimer_preload.so
```

## Use

```
LD_PRELOAD=$HOME/.cadence/qtimer_preload.so \
  QTIMER_LOG=$HOME/.cadence/qtimer.log \
  cadence-env -c 'virtuoso -log /tmp/v.log'   # or libManager ...
```

Reproduce the stall, then resolve the logged addresses against the tool's
binary/libs (all in `~/.cadence/IC251`):

```
x86_64-unknown-linux-gnu-addr2line -f -C -e <binary> 0x<addr>
```

(`x86_64-unknown-linux-gnu-addr2line` is in the nixpkgs x86_64 binutils.)
