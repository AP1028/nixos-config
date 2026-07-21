# Battery SSDT Notes

The battery SSDT (`ssdt-battery.aml`) is required for mobile NVIDIA GPUs
(RTX 5080 Laptop GPU etc.) to avoid Error 43. The NVIDIA mobile driver
checks for battery presence and refuses to load if absent.

## Side effect: Windows palm rejection

When the battery SSDT is injected via `-acpitable`, Windows classifies
the system as a laptop and enables Precision Touchpad palm rejection
(`AAPThreshold=2`). This blocks **left mouse clicks** when keyboard
keys are held — even for external/VirtIO mice.

### Fix

In the Windows guest, set the following registry values:

```powershell
Set-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\PrecisionTouchPad' \
    -Name AAPThreshold -Value 0
Set-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\PrecisionTouchPad' \
    -Name EnableEdgy -Value 0
```

Or run `C:\Users\Public\disable-palm-rejection.ps1` on boot.
