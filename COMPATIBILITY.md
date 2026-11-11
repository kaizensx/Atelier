# Atelier compatibility

Atelier supports **macOS 14 Sonoma, 15 Sequoia, 26 Tahoe and 27**, on **Apple silicon and Intel**.
The app is a universal binary (arm64 + x86_64, `LSMinimumSystemVersion` 14.0); the Dock Bridge
payload and loader are universal too (arm64e + x86_64).

Every feature asks `FeatureAvailability` before it shows its controls, so a Mac that cannot do
something says why ("Needs macOS 15", "Needs a Force Touch trackpad", "This Mac has no fan")
instead of failing. The Settings chapter opens with a **This Mac** card; please paste its
"Copy for a bug report" block into issues.

## How it was checked
- Tested live: macOS 27.3, MacBook Pro M5 Pro (XDR, notch), plus the x86_64 build under Rosetta.
- Everything else (14, 15, 26, real Intel hardware, M1–M4) is implemented from sources: yabai,
  InstantSpaceSwitcher, Stats, LinearMouse, MonitorControl, BrightIntosh, Hidden Bar,
  macos-defaults, Apple release notes, and reverse engineering with REA. **Reports from those
  setups are very welcome.**

## Version-dependent behaviour
| Area | 14 | 15 | 26 | 27 | Intel |
|---|---|---|---|---|---|
| Look (Liquid Glass) | material fallback | material fallback | native | native | same |
| Settings catalogue (317 keys) | keys outside their range are hidden in "Not on this macOS" | same | same | same | same |
| Instant Spaces | legacy swipe | legacy swipe | legacy swipe | swipe + payload | yes |
| Send window to Space | direct / compat ID | bridge if present | bridge (26.4+) | bridge | yes |
| Apple tiling conflict note | none (no tiling) | yes | yes | yes | yes |
| Screen recorder (Tools) | unavailable | yes | yes | yes | yes |
| Hot Corner launcher | Launchpad | Launchpad | Apps | Apps | yes |
| Icon styles (Clear/Tinted) | unavailable | unavailable | yes | yes | yes |
| Menu Bar Hider | 10,000 pt divider | same | same | measured divider (limited) | yes |
| Dock Bridge Spaces create/remove/move | yabai patterns | yabai patterns | yabai patterns | off (unverified) | yabai patterns |

## Hardware-dependent behaviour
- **XDR Boost:** XDR panels only (MacBook Pro 14/16 with XDR, Pro Display XDR); other HDR
  displays are limited; SDR displays unavailable.
- **Thermals:** per-chip SMC tables (Intel, M1–M6); fanless MacBook Air hides fans; desktops hide
  battery; Macs without a power key hide watts.
- **Trackpad Gestures / Haptics:** need a trackpad; haptics and the firm press need Force Touch.
  Magic Mouse is ignored by the gesture engine.
- **Keyboard Light:** backlit keyboards only.
- **Notch features** (Island HUD, Notch Shelf) fall back to the top centre on Macs without a notch.

## Beyond SIP (Dock Bridge)
Window opacity, pin on top, sticky windows, picture in picture, no shadows and Spaces Studio need
System Integrity Protection partly off. SIP can only be changed from recoveryOS; Atelier's Recovery
Assistant walks through it (QR checklist, copy command, Intel restart into Recovery) and finishes
setup with one administrator prompt afterwards. Turning SIP partly off lowers macOS security.
On macOS 27, Spaces Studio only switches desktops: adding, removing and reordering have no verified
Dock address yet, so those controls are hidden there. Removing the bridge works with SIP back on.
