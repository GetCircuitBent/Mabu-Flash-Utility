# Mabu Flash Utility

This repo contains the scripts and firmware patches needed to free a **Mabu** robot tablet from its factory software lock and install your own apps. The full process takes about fifteen minutes on a PC that has done it before, and about thirty minutes on a fresh machine.

---

## What You'll Need

### Hardware

- A Mabu unit
- The **USB programming harness** — a cable that connects to the 30-pin internal header inside the Mabu. This is the only way to communicate with the device; there is no external USB port on the Mabu itself

### PC

- Windows 10 or 11
- An internet connection (to download tools and install apps onto the Mabu)
- A WiFi network the Mabu can join — the script installs apps over WiFi after the flash

---

## Download This Repo

**Option A — Git** (if you have Git installed):
```
git clone https://github.com/GetCircuitBent/Mabu-Flash-Utility.git
```

**Option B — ZIP** (no Git needed):
1. Click the green **Code** button at the top of this page
2. Click **Download ZIP**
3. Unzip it somewhere permanent — the scripts run from that folder

---

## One-Time Setup

Run this once on each new PC before your first flash. It automatically downloads the Rockchip flashing tool and installs the USB drivers the Mabu needs.

1. Open **PowerShell as Administrator** (right-click the Start menu → *Windows PowerShell (Admin)*)
2. Navigate to the repo folder:
   ```powershell
   cd "path\to\Mabu-Flash-Utility"
   ```
3. Allow the scripts to run (Windows blocks them by default):
   ```powershell
   Set-ExecutionPolicy RemoteSigned -Scope CurrentUser
   ```
4. Run the setup script:
   ```powershell
   .\scripts\install-tools.ps1
   ```
   The script downloads and verifies all required tools. When it finishes, all boxes should show `[OK]`.

---

## Flash a Mabu

After setup, every flash follows the same three steps.

### Step 1 — Connect the harness

Plug the USB harness into the Mabu's internal header and into a USB port on your PC. Use the **same USB port every time** — the driver binding is per-port, and switching ports means running through the Zadig step again.

### Step 2 — Boot the Mabu

1. Short **ADKEY** (header pin 4) to **GND** (any of pins 1, 2, 6, 13, or 14) and hold it
2. Power the unit on while still holding ADKEY
3. Release ADKEY after a few seconds

Two things can happen:

- **Blank screen** — the Mabu is in Loader mode and ready to flash. Go straight to Step 3.
- **Android boots** — the Mabu came up normally. Join your WiFi network on the Mabu's screen, then go to Step 3. The script will enter Loader mode on its own.

### Step 3 — Run the flash script

From the repo root in your Administrator PowerShell window:

```powershell
.\scripts\flash-mabu.ps1 -RestoreMabu
```

The script handles everything from here:

- Detects whether the unit needs a data wipe or just the liberation patches
- Applies the patches over USB
- Reboots the unit into Android
- Asks you to connect the Mabu to WiFi (touch the screen to join your network when prompted)
- Installs F-Droid, Lawnchair, and the Mabu factory app
- Patches the SELinux policy so apps can access the motors
- Runs a self-test and prints a pass/fail summary

**The first time it runs**, the script may launch **Zadig** to bind the correct USB driver. When Zadig opens:
1. Go to **Options → List All Devices**
2. Select **Rockusb Device (USB ID 2207 320A)**
3. Set the target driver to **WinUSB**
4. Click **Replace Driver**
5. Switch back to PowerShell and press Enter to continue

This driver step only happens once per PC.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| Script says `adb.exe not found` | Run `winget install Google.PlatformTools` and restart PowerShell |
| Loader mode won't appear | Check D+/D− polarity on the harness; try holding ADKEY earlier during power-on |
| Script stops at WiFi step | Touch the Mabu screen, join your WiFi network, then press Enter in PowerShell |
| App installs fail | Make sure the Mabu and PC are on the same WiFi network |
| `execution of scripts is disabled` error | Run `Set-ExecutionPolicy RemoteSigned -Scope CurrentUser` and try again |

---

## Harness Wiring

The harness is a four-wire cable between a USB-A plug (into the PC) and four pins on the Mabu's internal 30-pin header. The header is 2 mm pitch, dual-row; pin 1 is at the GND/USB end, marked by the red stripe on the ribbon cable.

```
  USB-A (to PC)                        Mabu 30-pin header
  ┌────────────────┐                   (2 mm pitch · pin 1 at red-stripe end)
  │  1 · VBUS      │  — not connected —
  │                │
  │  2 · D−        │ ──────────────────  5 · OTG_DM
  │  3 · D+        │ ──────────────────  3 · OTG_DP
  │                │
  │  4 · GND       │ ──────────────────  1 · GND
  └────────────────┘

  If you see "device descriptor request failed": swap the D+ and D− wires.

  ───────────────────────────────────────────────────────────────────────
  ADKEY short  (hold during power-on to boot into Loader mode)

                                         4 · ADKEY ──┐
                                         6 · GND   ──┘  jumper wire or clip
```

VBUS is left unconnected — the Mabu runs on its own power supply, not USB bus power.

---

## Full Documentation

The full-detailed, developer-focused walkthrough — including background on what each phase does, the full pin-out of the 30-pin header, recovery procedures for unusual unit states, and detail on the permanent SELinux fix — is in [FLASH-A-NEW-MABU.md](FLASH-A-NEW-MABU.md).
