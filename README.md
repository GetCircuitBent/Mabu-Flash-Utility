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
   cd "C:\path\to\Mabu-Flash-Utility"
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

### Step 2 — Get the Mabu into Loader mode

The Mabu needs to be in Loader mode before the script can talk to it. Two ways in:

**If the Mabu is already on and reachable over ADB** (usual case after a previous flash):
```powershell
adb reboot loader
```
This is instant and reliable.

**If starting from a powered-off unit** (first flash, or no ADB access):
1. Hold **ADKEY** (header pin 4) shorted to **GND** (any of pins 1, 2, 6, 13, or 14)
2. While holding ADKEY, power the unit on
3. Keep holding until Windows detects a new device (a few seconds)
4. Release ADKEY

Holding ADKEY forces the unit straight into Loader mode and keeps it there — you won't race a ten-second window.

> **If you see "device descriptor request failed" in Device Manager:** the D+ and D− wires on your harness are swapped. Swap OTG_DP (pin 3) and OTG_DM (pin 5) and try again.

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

## Full Documentation

The detailed walkthrough — including background on what each phase does, the full pin-out of the 30-pin header, recovery procedures for unusual unit states, and the permanent SELinux fix — is in [FLASH-A-NEW-MABU.md](FLASH-A-NEW-MABU.md).
