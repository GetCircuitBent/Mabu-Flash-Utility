# Mabu Flash Utility
This repo contains the scripts and firmware patches needed to free a **Mabu** robot tablet from its factory software lock and install your own apps. The full process takes about fifteen minutes on a PC that has done it before, and about thirty minutes on a fresh machine.

---

## What You'll Need
### Hardware
- A Mabu unit
- The **USB programming harness** (a 30-pin IDC cable, 2.0 mm pitch) that connects to the internal header inside the Mabu, with a USB-A connector and an ADKEY switch wired to it. This is the only way to communicate with the device; there is no external USB port on the Mabu itself

### PC
- Windows 10 or 11
- An internet connection (to download tools and install apps onto the Mabu)
- A Wi-Fi network the Mabu can join; the script installs apps over Wi-Fi after the flash

---

## Download This Repo
**Option A: Git** (if you have Git installed):
```
git clone https://github.com/GetCircuitBent/Mabu-Flash-Utility.git
```

**Option B: ZIP** (no Git needed):
1. Click the green **Code** button at the top of this page
2. Click **Download ZIP**
3. Unzip it somewhere permanent. The scripts run from that folder.

> **Note on the ZIP:** it extracts to a folder that contains *another* folder of the
> same name (`Mabu-Flash-Utility-main\Mabu-Flash-Utility-main\`). The inner one is
> the repo: it's the folder holding `scripts\`, `tools\` and `firmware\`. That's the
> one to `cd` into.

---

## One-Time Setup
Run this once on each new PC before your first flash. It installs ADB, the Rockchip flashing tool, and the USB drivers the Mabu needs.

1. Open **PowerShell as Administrator** (right-click the Start menu, then *Windows PowerShell (Admin)*). The flash script requires this; it replaces USB drivers, which needs elevation.
2. Navigate to the repo folder (the one containing `scripts\`):
   ```powershell
   cd "path\to\Mabu-Flash-Utility"
   ```
3. Allow the scripts to run (Windows blocks them by default):
   ```powershell
   Set-ExecutionPolicy RemoteSigned -Scope CurrentUser
   ```
4. **If you downloaded the ZIP**, also clear the "downloaded from the internet" mark, or Windows will refuse to run the scripts even after step 3:
   ```powershell
   Get-ChildItem -Recurse -Filter *.ps1 | Unblock-File
   ```
5. Run the setup script:
   ```powershell
   .\scripts\install-tools.ps1
   ```
   The script downloads and verifies all required tools. When it finishes, all boxes should show `[OK]`.

---

## Flash a Mabu
After setup, every flash follows the same three steps.

### Step 1: Connect the Harness
Plug the USB harness into the Mabu's internal header and into a USB port on your PC. Use the **same USB port every time**; the driver binding is per-port, and switching ports means running through the Zadig step again.

### Step 2: Boot the Mabu
1. Hold the ADKEY switch on the harness
2. Power the unit on while still holding ADKEY
3. Release ADKEY after a few seconds

Two things can happen:
- **Blank screen.** The Mabu is in Loader mode and ready to flash. Go straight to Step 3.
- **Android boots.** The Mabu came up normally. Join your Wi-Fi network on the Mabu's screen, then go to Step 3. The script will enter Loader mode on its own.

### Step 3: Run the Flash Script
From the repo root in your Administrator PowerShell window:

```powershell
.\scripts\flash-mabu.ps1
```

The script handles everything from here:
- Repairs the Mabu's USB driver binding if a previous Zadig run broke it
- Detects whether the unit needs a data wipe or just the liberation patches
- Applies the patches over USB
- Reboots the unit into Android
- Asks you to connect the Mabu to Wi-Fi (touch the screen to join your network when prompted)
- Installs F-Droid, Lawnchair, and the Mabu factory app
- Patches the SELinux policy so apps can access the motors
- Runs a self-test and prints a pass/fail summary

**The first time it runs**, the script may launch **Zadig** to bind the driver the Loader needs. When Zadig opens:
1. Go to **Options > List All Devices**
2. Go to **Options** and uncheck **Ignore Hubs or Composite Parents**
3. Select the device whose USB ID is **2207 320A** (it may be listed as "Unknown Device"; match on the USB ID, not the name)
4. Set the target driver to **WinUSB**
5. Click **Replace Driver**
6. Switch back to PowerShell and press Enter to continue

> **Only ever replace the driver on 2207 320A.** If that USB ID is not in the list,
> close Zadig without replacing anything: the Loader is not on the bus yet, and
> there is nothing valid to pick. The other Rockchip IDs (2207 0006, and 2207 0010
> through 0015, listed as "ADB Interface" or "MTP") are the Mabu's Android-mode
> interfaces. Replacing the driver on one of those stops ADB from seeing the
> tablet, and the flash cannot continue until it is undone. The script refuses to
> open Zadig unless the Loader is actually present, so this only comes up if you
> launch Zadig yourself.

This driver step happens once per PC, per USB port.

---

## Troubleshooting
**The PC can't see the Mabu at all?** Start here. This read-only diagnostic reports
which driver is bound to each Rockchip USB ID and what's missing. It changes nothing:

```powershell
.\scripts\diagnose-usb.ps1 -Watch
```

`-Watch` polls for ~30 seconds, so you can start it first and *then* power the unit
on; it catches the ~10-second Loader window instead of you racing it.

| Symptom | Fix |
|---|---|
| Script says `adb.exe not found` | Re-run `.\scripts\install-tools.ps1`, then restart PowerShell |
| Script says it must run as Administrator | Reopen PowerShell via right-click Start menu > *Windows PowerShell (Admin)* |
| `rkdeveloptool.exe not found` | You're running from the wrong folder, or the download was incomplete. Run `.\scripts\install-tools.ps1` from the folder containing `scripts\` |
| Loader mode won't appear | Check D+/D- polarity on the USB wires; try holding ADKEY earlier during power-on |
| Windows shows the Mabu (as "H7R", "ADB Interface" or "MTP") but the script says `No adb device and no Loader` | Zadig was pointed at the Android-mode device at some point, which stops ADB from seeing it. The script detects this and repairs it in place, so re-run it first. If it still reports the misbinding, follow the undo steps it prints |
| Script stops at Wi-Fi step | Touch the Mabu screen, join your Wi-Fi network, then press Enter in PowerShell |
| App installs fail | Make sure the Mabu and PC are on the same Wi-Fi network |
| `execution of scripts is disabled` error | Run `Set-ExecutionPolicy RemoteSigned -Scope CurrentUser`. If you used the ZIP, also run `Get-ChildItem -Recurse -Filter *.ps1 \| Unblock-File` |

---

## Harness Wiring
The harness uses a 30-pin IDC ribbon cable (2.0 mm pitch); pin 1 is at the GND/USB end, marked by the red stripe. On the PC end, wire a USB-A connector and an ADKEY switch as shown below.

```
  USB-A (to PC)                        30-pin IDC cable
  ┌────────────────┐                   (2 mm pitch · pin 1 at red-stripe end)
  │  1 · VBUS      │  (not connected)
  │                │
  │  2 · D-        │ ──────────────────  5 · OTG_DM
  │  3 · D+        │ ──────────────────  3 · OTG_DP
  │                │
  │  4 · GND       │ ──────────────────  1 · GND
  └────────────────┘

  ───────────────────────────────────────────────────────────────────────
  ADKEY switch  (hold during power-on to boot into Loader mode)

                                         4 · ADKEY ──┤ switch ├──  6 · GND
```

- VBUS is left unconnected. The Mabu runs on its own power supply, not USB bus power.
- If you see "device descriptor request failed": the D+ and D- wires are reversed; swap them.

---

## Detailed Documentation
The detailed walkthrough (background on what each phase does, the full pin-out of the 30-pin header, recovery procedures for unusual unit states, and the permanent SELinux fix) is in [FLASH-A-NEW-MABU.md](FLASH-A-NEW-MABU.md).
