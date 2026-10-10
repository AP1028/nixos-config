# Merging a stale PR onto a moved master — VoodooI2CHID + PR #75

**Purpose.** Rebuild `VoodooI2CHID.kext` from upstream master **with the unmerged PR #75
("Trackpoint") applied**, for use on the ASUS ROG Zephyrus G16 (2025, Arrow Lake-H) hackintosh.

**Status of this document.** The *merge* described here is **complete and verified**. The
*build* section documents the toolchain and the layout trap; the build itself was still in
progress when this was written, so treat §7 as instructions rather than a log of a finished
run.

---

## 1. The problem

PR #75 is open, unmerged, and **stale**:

```
PR #75 "Trackpoint"  —  state: open, merged: false
  opened:  2024-06-11
  base:    89fa5b64c1fc38b4b370d45c7ad0d8d632e3b86c
  head:    bf31bf212a73947dfc9b033b10cdfad22f77b8e5
  files:   6   (2 new sources + 3 edits + the .pbxproj)
  mergeable_state: dirty
```

Applying its diff to current master fails on three files:

```
error: patch failed: VoodooI2CHID/VoodooI2CMultitouchHIDEventDriver.cpp:207
error: patch failed: VoodooI2CHID/VoodooI2CMultitouchHIDEventDriver.hpp:63
error: patch failed: VoodooI2CHID/VoodooI2CTouchscreenHIDEventDriver.cpp:313
```

A 3-way apply (`git apply -3`) gets four files through but leaves the `.hpp` conflicted.

**The naive fix — hand-resolving the conflict — is the wrong move.** It silently merges two
independent lines of development and you cannot tell afterwards whether anything was lost.

---

## 2. The method

The insight: *a PR's diff applies cleanly to the commit it was opened against.* So reconstruct
history rather than patching a moving target.

1. **Find the PR's base commit** — the GitHub API exposes it as `base.sha`.
2. **Check out that base** (detached HEAD).
3. **Apply the PR diff there** — it applies cleanly, because that is what it was written for.
4. **Commit it**, so later commits can be layered on top.
5. **Cherry-pick every commit master gained after the base.** Anything that conflicts is now a
   *real* conflict between two known commits, not an artefact of a stale diff — and you can
   judge each one on its merits.

The result is provably **master + PR** — see §5.

---

## 3. The exact commands

```bash
# ---- 1. base commit ---------------------------------------------------------
curl -s https://api.github.com/repos/VoodooI2C/VoodooI2CHID/pulls/75 \
  | python3 -c "import json,sys; d=json.load(sys.stdin); \
      print(d['base']['sha'], d['head']['sha'], d['mergeable_state'])"
# -> 89fa5b64c1fc38b4b370d45c7ad0d8d632e3b86c bf31bf2... dirty

BASE=89fa5b64c1fc38b4b370d45c7ad0d8d632e3b86c
MASTER=$(git rev-parse master)          # record where master was

# ---- 2. the PR diff ---------------------------------------------------------
curl -sL https://github.com/VoodooI2C/VoodooI2CHID/pull/75.diff -o /tmp/pr75.diff

# ---- 3. reconstruct ---------------------------------------------------------
git clone https://github.com/VoodooI2C/VoodooI2CHID.git && cd VoodooI2CHID
git checkout -q "$BASE"
git apply /tmp/pr75.diff                 # applies cleanly, zero conflicts
git add -A && git commit -q -m "PR #75 Trackpoint"

# ---- 4. what did master gain since the base? --------------------------------
git log --oneline --reverse "$BASE".."$MASTER"
#   f8ba848  Fix docs in newer versions of macOS (#76)
#   a478fd6  Passthrough Confidence Bit to macOS (#74)
#   2727793  Remove duplicate setProperty(VoodooI2CServices) (#77)

# ---- 5. layer them on -------------------------------------------------------
git cherry-pick f8ba848 a478fd6 2727793
```

### The one conflict, and how to judge it

Only `f8ba848` (#76) conflicted, in `VoodooI2CMultitouchHIDEventDriver.hpp`:

```c
<<<<<<< HEAD
    struct {                    <- PR #75's side
=======
    struct Digitiser {          <- #76 names an anonymous struct
>>>>>>> f8ba848
```

**This is not a real disagreement** — #76 names a struct, PR #75 adds a blank line nearby.

**Resolve by keeping the incoming change**, because later commits reference the name:

```bash
python3 - <<'PY'
import re
p = "VoodooI2CHID/VoodooI2CMultitouchHIDEventDriver.hpp"
s = open(p).read()
s = re.sub(r"<<<<<<< HEAD\n.*?\n=======\n(.*?)>>>>>>> [^\n]*\n", r"\1", s, flags=re.S)
open(p, "w").write(s)
PY
git add -A && GIT_EDITOR=true git cherry-pick --continue
git cherry-pick --quit      # clears the sequencer if it is left mid-operation
```

---

## 4. Gotchas hit while doing this

| Symptom | Cause | Fix |
|---|---|---|
| `error: you need to resolve your current index first` | a conflicted index is **not** cleared by `git checkout -- .` | `git reset --hard <commit>` |
| `error: cherry-pick is already in progress` | the sequencer is still active after resolving | `git cherry-pick --continue`, then `--quit` once nothing is pending |
| `The previous cherry-pick is now empty` | the change is already present in the tree | `git cherry-pick --skip` (do **not** `--allow-empty`) |
| PR changes vanish unexpectedly | `git stash -u` swept them up | re-apply, or avoid stashing mid-sequence |

---

## 5. Verification — the part that makes this trustworthy

A merge is only reproducible if you can *prove* what you ended up with. Compare the result
against master; the diff must contain **only the PR's changes**:

```bash
git diff --stat "$MASTER" HEAD
```

Observed, and this is the acceptance criterion:

```
 VoodooI2CHID.xcodeproj/project.pbxproj             |  8 +++
 VoodooI2CHID/VoodooI2CHIDTrackpointWrapper.cpp     | 40 ++++++++++++
 VoodooI2CHID/VoodooI2CHIDTrackpointWrapper.hpp     | 28 ++++++++
 VoodooI2CHID/VoodooI2CMultitouchHIDEventDriver.cpp | 76 +++++++++++++++++++++-
 VoodooI2CHID/VoodooI2CMultitouchHIDEventDriver.hpp | 13 +++-
 5 files changed, 163 insertions(+), 2 deletions(-)
```

Nothing else differs — so every other master commit is present, and **this tree is
exactly master + PR #75**. Spot-check the individual fixes landed:

```bash
grep -c "Confidence"      VoodooI2CHID/VoodooI2CMultitouchHIDEventDriver.cpp   # #74  -> 1
grep -c "struct Digitiser" VoodooI2CHID/VoodooI2CMultitouchHIDEventDriver.hpp  # #76  -> 1
ls VoodooI2CHID/VoodooI2CHIDTrackpointWrapper.cpp                              # PR75 -> present
```

Because `$BASE` and `$MASTER` are recorded SHAs, this is fully reproducible by anyone.

---

## 6. Why bother with the later commits at all

The three commits master gained are small, and two are functionally relevant:

| Commit | Subject | Relevance |
|---|---|---|
| `f8ba848` | Fix docs in newer versions of macOS (#76) | names the `Digitiser` struct; referenced by later code |
| `a478fd6` | Passthrough Confidence Bit to macOS (#74) | **functional** — palm-rejection confidence to macOS |
| `2727793` | Remove duplicate setProperty(VoodooI2CServices) (#77) | **functional** — duplicate property removal |

`base + PR75 + these three == master + PR75`. Skipping them would silently drop two
functional touchpad fixes.

---

## 6b. PR #75 does not compile — it is an incomplete fragment

**Read this before trying to build PR #75.** After merging it cleanly (section 3), the build fails:

```
error: unknown type name 'VoodooI2CTrackpointEvent'
error: no member named 'handleTrackpointReport' in 'VoodooI2CMultitouchInterface'
error: use of undeclared identifier 'CMP_ABSOLUTETIME'
```

These are **PR #75's own additions**, and the symbols exist nowhere:

| Symbol | Where it would have to live | Status |
|---|---|---|
| `VoodooI2CTrackpointEvent` | VoodooI2C / VoodooInput | **not defined anywhere** |
| `handleTrackpointReport` | `VoodooI2C/Multitouch Support/VoodooI2CMultitouchInterface.hpp` | **absent** |
| `CMP_ABSOLUTETIME` | MacKernelSDK `libkern/OSBase.h` | present — but see 7.4 |

**Conclusion: PR #75 depends on companion changes in `VoodooI2C` and/or `VoodooInput` that
were never merged.** It cannot be built as-is, and no companion PR was found.

**The practical build is therefore plain master.** PR #75 is *trackpoint* support (the nub),
not the touchpad, so master alone still answers the question in section 8.

---

## 7. Building it

### 7.0 The working build, end to end

Verified on this machine: **13/13 objects compiled, 0 failures; linked binary 187,792 bytes.**

```bash
git clone --depth 1 https://github.com/VoodooI2C/VoodooI2C.git
git clone --depth 1 https://github.com/acidanthera/MacKernelSDK.git

cd VoodooI2C && git submodule update --init --recursive      # pulls Dependencies/VoodooGPIO
cd "VoodooI2C Satellites" && git clone https://github.com/VoodooI2C/VoodooI2CHID.git

cd VoodooI2CHID
SDK=$(xcrun --show-sdk-path)
KH="$SDK/System/Library/Frameworks/Kernel.framework/Headers"
mkdir -p build

for f in VoodooI2CHID/*.cpp VoodooI2CHID/Overrides/*.cpp VoodooI2CHID/Sensors/*.cpp; do
  clang++ -arch x86_64 -mmacosx-version-min=10.11 -isysroot "$SDK" \
    -std=gnu++0x -mkernel -nostdinc -nostdinc++ \
    -isystem "$HOME/MacKernelSDK/Headers" \
    -isystem "$KH" \
    -I VoodooI2CHID \
    -I "$HOME/VoodooI2C/Multitouch Support" \
    -I "$HOME/VoodooI2C/VoodooI2C/VoodooI2CDevice" \
    -include libkern/OSBase.h \
    -fno-builtin -fno-common -fno-exceptions -fno-rtti -fno-stack-protector \
    -Wno-deprecated-declarations -D__KERNEL__ -DKERNEL \
    -c "$f" -o "build/$(basename "$f" .cpp).o" || echo "FAILED: $f"
done

ld -arch x86_64 -r -kext -o build/VoodooI2CHID.bin build/*.o
```

**That link line is NOT sufficient** - see 7.7. It produces a kext bundle that
loads but is completely **inert**.

Then assemble the bundle and **substitute the Xcode placeholders** (7.6).

### 7.1 `xcodebuild` is unavailable — and not required

A Command Line Tools install provides `clang` but **not** `xcodebuild`:

```
xcodebuild: error: tool 'xcodebuild' requires Xcode, but active developer directory
            '/Library/Developer/CommandLineTools' is a command line tools instance
```

Full Xcode is ~10 GB. A kext is just a bundle containing a Mach-O, so `clang` can drive it
directly.

```bash
sudo softwareupdate --list                                  # find the CLT package
sudo softwareupdate --install "Command Line Tools for Xcode-16.4"
```

### 7.2 The source layout trap

`VoodooI2CHID.hpp` contains:

```c
#include "../../../Dependencies/helpers.hpp"
```

`Dependencies/` is **not** in the satellite repo — it lives in the **main `VoodooI2C` repo**.
The satellite is designed to be checked out *inside* it:

```
VoodooI2C/                                  <- main repo (has Dependencies/, .xcworkspace)
├── Dependencies/
│   └── helpers.hpp
└── VoodooI2C Satellites/
    └── VoodooI2CHID/                       <- this repo goes here
        └── VoodooI2CHID/VoodooI2CHIDDevice.hpp
```

From `VoodooI2C/VoodooI2C Satellites/VoodooI2CHID/VoodooI2CHID/`, `../../../Dependencies/`
resolves to `VoodooI2C/Dependencies/` — correct. Built anywhere else you get:

```
fatal error: '../../../Dependencies/helpers.hpp' file not found
```

### 7.3 `MacKernelSDK` is required

The project sets:

```
KERNEL_EXTENSION_HEADER_SEARCH_PATHS = "$(PROJECT_DIR)/../../MacKernelSDK/Headers"
```

So clone [acidanthera/MacKernelSDK](https://github.com/acidanthera/MacKernelSDK) as well, or
pass its `Headers/` with `-isystem`.

### 7.4 `-nostdinc` is mandatory

Without it the userland SDK headers shadow the kernel's, and you get:

```
error: typedef redefinition with different types
       ('UnsignedWide' vs 'UInt64')
  MacTypes.h:289   vs   libkern/OSTypes.h:75
```

Kexts must see kernel headers **only**. Include `Kernel.framework/Headers` and
`MacKernelSDK/Headers`, and exclude the userland SDK include tree.

### 7.5 Compile flags

Matched to the project's own settings (`ARCHS = x86_64`,
`MACOSX_DEPLOYMENT_TARGET = 10.11`, `CLANG_CXX_LANGUAGE_STANDARD = gnu++0x`):

```bash
SDK=$(xcrun --show-sdk-path)
KH="$SDK/System/Library/Frameworks/Kernel.framework/Headers"
MKS="$HOME/MacKernelSDK/Headers"

clang++ -arch x86_64 \
        -mmacosx-version-min=10.11 \
        -isysroot "$SDK" \
        -std=gnu++0x \
        -mkernel \
        -nostdinc -nostdinc++ \
        -isystem "$KH" -isystem "$MKS" \
        -I VoodooI2CHID \
        -fno-builtin -fno-common -fno-exceptions -fno-rtti -fno-stack-protector \
        -D__KERNEL__ -DKERNEL \
        -c <source>.cpp -o <source>.o
```

Fourteen sources: `VoodooI2CHID/*.cpp`, `Overrides/*.cpp`, `Sensors/*.cpp`, plus the new
`VoodooI2CHIDTrackpointWrapper.cpp`.

Relink with `ld -arch x86_64 -r`, then assemble the bundle:

```
VoodooI2CHID.kext/
└── Contents/
    ├── Info.plist                 (from the repo)
    ├── MacOS/VoodooI2CHID         (the linked Mach-O)
    └── _CodeSignature/            (optional; OpenCore does not verify it)
```

### 7.6 The Info.plist contains Xcode build variables

The repo's `Info.plist` ships with **unsubstituted Xcode variables**. Xcode replaces them at
build time; a manual build must do it itself, or the kext is unusable:

```
CFBundleIdentifier = $(PRODUCT_BUNDLE_IDENTIFIER)   -> com.alexandred.VoodooI2CHID
CFBundleExecutable = $(EXECUTABLE_NAME)             -> VoodooI2CHID
                                                       (also $(PRODUCT_NAME))
```

Values are defined in `VoodooI2CHID.xcodeproj/project.pbxproj`:

```
PRODUCT_BUNDLE_IDENTIFIER = com.alexandred.VoodooI2CHID;
PRODUCT_NAME              = "$(TARGET_NAME)";          # -> VoodooI2CHID
```

Substitute and verify:

```bash
plutil -replace CFBundleIdentifier -string com.alexandred.VoodooI2CHID \
       VoodooI2CHID.kext/Contents/Info.plist
plutil -replace CFBundleExecutable -string VoodooI2CHID \
       VoodooI2CHID.kext/Contents/Info.plist
plutil -lint VoodooI2CHID.kext/Contents/Info.plist
grep -oE '\$\([A-Za-z_]+\)' VoodooI2CHID.kext/Contents/Info.plist   # must be empty
```

Bundle produced:

```
VoodooI2CHID.kext/Contents/Info.plist              10518 bytes
VoodooI2CHID.kext/Contents/MacOS/VoodooI2CHID     187792 bytes
```

No `_CodeSignature/` is needed — OpenCore does not verify it.

### 7.7 CRITICAL: `libkmodc++` and `_kmod_info` - or the kext is inert

**This is the single most important trap in the whole build, and it fails
*silently and confusingly*.**

A kext binary needs a `_kmod_info` symbol (a `kmod_info_t` struct). `ld` does not
create it; Xcode's kext product does. Without it, OpenCore's prelinked injection
**silently skips the kext** - it simply never appears in `kmutil showloaded`, with
no error anywhere.

Worse, creating it *incorrectly* also fails. A hand-written struct with
`start = 0, stop = 0` produces a kext that **loads** (it appears in
`kmutil showloaded` and gets a load address) but **registers no classes at all**,
because `kmod_start` is what invokes the C++ static constructors, and those are
what register `OSMetaClass`. Manually loading such a kext gives:

```
Error Domain=KMErrorDomain Code=71 "Loading extension failed: Loading Kext
com.alexandred.VoodooI2CHID v1 ... kext (kmod) start/stop routine failed
(-603946985)"
```

Under OpenCore you never see even that - the kext just does not work, and
`ioreg` shows none of its classes.

#### The fix

MacKernelSDK's own README states the required link line:

```
# The linkline must look like this.
#    *.o -lkmodc++ kmod_info.o -lkmod
```

For a **C++** kext, `libkmodc++` supplies the constructor-aware `_start`. Provide
`kmod_info` pointing at real routines:

```c
/* build/kmod_info.c */
#include <mach/kmod.h>

extern kern_return_t _start(kmod_info_t *, void *);
extern kern_return_t _stop(kmod_info_t *, void *);

kmod_info_t KMOD_INFO_NAME = {
    0, KMOD_INFO_VERSION, -1U,
    { "com.alexandred.VoodooI2CHID" },   /* must match CFBundleIdentifier */
    { "1" },                             /* must match CFBundleVersion     */
    -1, 0, 0, 0, 0,
    _start,
    _stop
};
```

Compile the C++ stubs and link them in (note the libraries live in
`MacKernelSDK/Library/universal/`, **not** `x86_64/`):

```bash
U="$HOME/MacKernelSDK/Library/universal"

clang -arch x86_64 -mmacosx-version-min=10.11 -isysroot "$SDK" -mkernel \
      -nostdinc -isystem "$MKS" -isystem "$KH" \
      -fno-builtin -fno-common -fno-stack-protector \
      -D__KERNEL__ -DKERNEL -c build/kmod_info.c -o build/kmod_info.o

for f in cplus_start.c cplus_stop.c; do
  clang -arch x86_64 -mmacosx-version-min=10.11 -isysroot "$SDK" -mkernel \
        -nostdinc -isystem "$MKS" -isystem "$KH" \
        -fno-builtin -fno-common -fno-stack-protector \
        -D__KERNEL__ -DKERNEL \
        -c "$HOME/MacKernelSDK/Library/kmod/$f" -o "build/${f%.c}.o"
done

ld -arch x86_64 -r -kext -o build/VoodooI2CHID.final \
   $(ls build/*.o | grep -vE "kmod_info|cplus_start|cplus_stop" | tr "\n" " ") \
   build/kmod_info.o build/cplus_start.o build/cplus_stop.o \
   "$U/libkmodc++.a" "$U/libkmod.a"
```

#### Verify before installing

```bash
file build/VoodooI2CHID.final                       # Mach-O 64-bit kext bundle
nm -g build/VoodooI2CHID.final | grep kmod_info     # exactly one, type D
```

Expected result on this machine: **185,232 bytes**, `kmod_info=1`.

`nm -u` will still show ~489 undefined symbols (`IOFree`, `IOLockAlloc`, ...) -
those resolve against the kernel and are normal.

#### Testing note

A kext **cannot be replaced while loaded** - `kmutil unload` fails with "kext is
in use or retained", and reloading hits the already-loaded instance, so a live
swap cannot validate a rebuild. **Test by installing to the ESP and rebooting.**

### 7.8 Installation

The kext must go to **both** boot paths, since this machine boots either:

```
USB stick:    /Volumes/1401/EFI/OC/Kexts/VoodooI2CHID.kext
internal ESP: EFI/OC/Kexts/VoodooI2CHID.kext        (mount: sudo diskutil mount disk0s1)
```

---

## 8. Open question this build is meant to answer

`VoodooI2CHID.kext` currently **fails to load** on this machine. Everything else in the I2C
stack loads and works:

```
✓ VoodooI2C            loaded, attached to the I2C controller
✓ VoodooI2CControllerDriver   matched, active
✓ VoodooGPIO           loaded
✓ VoodooI2CServices    loaded
✗ VoodooI2CHID         NOT loaded
✗ VoodooInput          NOT loaded
```

Its `Info.plist` is valid, its declared dependency (`com.alexandred.VoodooI2C 2.0`) is
satisfied, and its ACPI device (`ASUP`, with `_CID = PNP0C50`) is present and matched. The
installed binary came from Dortania's build-repo (commit `5c0c99c`), not from a release.

**Hypothesis:** the prebuilt binary is the problem, and a locally built one will load. If it
does not, the ceiling is elsewhere (upstream's Sequoia work is still unmerged), and that is a
useful negative result.

---

## 9. References

- PR #75 — https://github.com/VoodooI2C/VoodooI2CHID/pull/75
- VoodooI2CHID — https://github.com/VoodooI2C/VoodooI2CHID
- VoodooI2C (main repo, holds `Dependencies/`) — https://github.com/VoodooI2C/VoodooI2C
- MacKernelSDK — https://github.com/acidanthera/MacKernelSDK
- Patch URL pattern for any PR: `https://github.com/<owner>/<repo>/pull/<N>.diff`
- Base-commit metadata: `https://api.github.com/repos/<owner>/<repo>/pulls/<N>`
