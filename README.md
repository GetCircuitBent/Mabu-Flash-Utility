# Mabu Flash Utility
This repo frees a **Mabu** robot tablet from its factory software lock, installs a normal home screen and app store, and unlocks access to its motors, so you can install and run your own apps. It auto-detects the unit's state, applies everything it needs, and stops with a clear message the moment anything goes wrong.

A flash takes about **15 minutes** on a PC that has done it before, and about **30 minutes** the first time (most of that is the one-time setup).

---

## Two Ways to Run It
Both options run the same flash logic and produce the same result. Pick one.

| | **Installer (GUI)** | **Scripts (PowerShell)** |
|---|---|---|
| Best for | Anyone who just wants it done | Benches, repeat flashing, anything scripted |
| You download | One `.exe` from Releases | This repo (ZIP or Git) |
| Setup needed | None; it fetches its own tools | `install-tools.ps1`, once per PC |
| Runs as | Double-click, self-elevates | Administrator PowerShell |
| Status | First packaged build, **not yet validated on a tablet** | The known-good path |

If you are flashing a unit you cannot afford to re-flash, use the scripts.

---

## What You'll Need
### Hardware
- A Mabu unit
- The **USB programming harness**: a 30-pin ribbon cable that plugs into the header inside the Mabu, ending in a USB-A plug and an **ADKEY** button. This is the only way to talk to the Mabu; there's no external USB port on the device. (Wiring diagram is at the bottom of this page.)

### PC
- **Windows 10 or 11**
- An **internet connection** (to download tools and apps)
- A **Wi-Fi network the Mabu can join.** Partway through, the Mabu boots up and the flash finishes over Wi-Fi; you'll join it to your network on its own touchscreen when prompted.

---

## Option 1: The Installer
Download **`MabuFlashSetup.exe`** from the [latest release](https://github.com/GetCircuitBent/Mabu-Flash-Utility/releases/latest) and double-click it. That is the only file you need.

On first run it downloads the payload (about 89 MB), checks it against a published SHA-256, installs to `%LOCALAPPDATA%\MabuFlash\`, and opens the GUI. Later launches go straight to the GUI, and work offline.

There are **no prerequisites**: no PowerShell, no execution policy to change, no separate tool setup. The GUI shows two progress bars (flashing and validating) and raises a prompt card at each of the [points where it needs you](#what-happens-during-a-flash).

> **Windows SmartScreen will warn you.** The installer is not code-signed yet. Click **More info**, then **Run anyway**. Verify you downloaded it from the Releases page linked above.

> **Not yet hardware-validated.** This build is verified on a developer machine but has not flashed a real tablet. Treat the first run as a test.

Now connect the harness and power on the Mabu (see [Flash a Mabu](#flash-a-mabu), steps 1 and 2), then follow the prompts.

---

## Option 2: The Scripts
### Download
**Option A: ZIP** (no extra software needed):

1. Click the green **Code** button at the top of this page.
2. Click **Download ZIP**.
3. Unzip it to a **permanent location** (e.g. `C:\Mabu-Flash-Utility`). The scripts run from that folder, so don't leave it in Downloads or a temp folder.

> **Note on the ZIP:** it extracts to a folder containing *another* folder of the same name (`Mabu-Flash-Utility-main\Mabu-Flash-Utility-main\`). The inner one is the repo: it's the folder holding `scripts\`, `tools\` and `firmware\`. That's the one to `cd` into.

**Option B: Git** (if you already have Git):
```
git clone https://github.com/GetCircuitBent/Mabu-Flash-Utility.git
```

### One-Time Setup
Do this **once per PC**. It installs the flashing tools and the USB drivers the Mabu needs.

Open **PowerShell as Administrator** (right-click the Start button → **Terminal (Admin)** or **Windows PowerShell (Admin)**) for all of the steps below, and keep this same window open for the flash itself.

**1. Allow the scripts to run.** Windows blocks downloaded scripts by default:
```powershell
Set-ExecutionPolicy RemoteSigned -Scope CurrentUser
```

If you used the ZIP, also clear the "downloaded from the internet" mark, or Windows refuses to run the scripts even after the step above:
```powershell
Get-ChildItem -Recurse -Filter *.ps1 | Unblock-File
```

**2. Run the setup script.** Move into the folder you unzipped (replace the path with wherever you put it):
```powershell
cd "C:\Mabu-Flash-Utility"
.\scripts\install-tools.ps1
```
This sets up ADB, the Rockchip flashing tool, and the Zadig USB helper. When it finishes, the core checks should read **`[OK]`**.

> **About WSL (optional):** the setup script also offers to install WSL/Ubuntu. The flash **does not need it** for the normal case; it patches the motor policy right on the Mabu. WSL is only used as an automatic fallback on the rare unit where that patch needs a full re-flash. If you'd rather not install it now, you can skip it; the flash will tell you if it ever needs it. If setup does install WSL, it will ask you to **restart the PC**, then run `.\scripts\install-tools.ps1` once more.

**3. Install the Android USB driver.**
```powershell
.\scripts\install-android-driver.ps1
```
This prepares the driver and prints the exact **Device Manager** clicks to install it. Run it with the Mabu connected: it reads the hardware ID your unit actually reports and adds that to the driver, which is what makes the Device Manager step work on units whose USB interfaces are ordered differently.

That's it. You won't need to repeat setup on this PC.

---

## Flash a Mabu
### Step 1: Connect the Harness
Plug the USB harness into the Mabu's internal header and into a USB port on your PC. **Use the same USB port every time**; the driver binding is tied to the port, and switching ports means redoing the Zadig step once.

### Step 2: Start the Flash
**Installer:** the GUI is already open; click **Flash**.

**Scripts:** in the same **Administrator** PowerShell window, from the repo folder:
```powershell
.\scripts\flash-mabu.ps1
```
That's the whole command; no options are needed. This is the same flasher the GUI drives. It immediately starts watching for the Loader.

### Step 3: Boot the Mabu Holding ADKEY
With the flash already running, boot the tablet **while holding ADKEY** (short header pin 4 to GND). Either way of booting works, unplug and replug the harness or use the power button; just keep ADKEY held through the boot. The flasher catches the Rockchip Loader as the unit comes up and moves straight into the flash.

**If the Loader does not catch** (the tablet boots to Android, or lands on the recovery "No command" screen), reboot it to Android, then unplug and replug the harness USB and listen for the Windows **"new USB device" chime**:
- **No chime: it's a hardware problem.** The data link isn't there. Check the harness connections and the USB cable, then retry.
- **Chime plays: the link is fine, the Loader window was just missed.** Retry this step (boot holding ADKEY).

### Step 4: Follow the Prompts
Once the Loader is caught, the flasher runs on its own, liberation, reboot to Android, a pause for you to join Wi-Fi, app installs over Wi-Fi, and the self-tests (it re-runs them if any fail). Both paths tell you exactly what to do when they need you, as console prompts or GUI prompt cards.

---

## What Happens During a Flash
In order, the flasher will:

1. **Repair the USB driver binding** if a previous Zadig run left the tablet invisible to ADB.
2. **Figure out the unit automatically** and decide whether a data wipe is needed (a factory-locked unit gets wiped; an already-freed one doesn't).
3. **(First PC only) Launch Zadig** to install the driver the Loader needs. When Zadig opens: **Options → List All Devices**, then **Options → uncheck Ignore Hubs or Composite Parents**, pick the device with **USB ID `2207 320A`**, set the driver to **WinUSB**, and click **Replace Driver**. Then continue. This happens once per PC, per USB port.
   > **Only ever replace the driver on `2207 320A`.** If that USB ID is not listed, close Zadig without replacing anything. The other Rockchip IDs (`2207 0006`, and `2207 0010` through `0015`, shown as "ADB Interface" or "MTP") are the Mabu's Android-mode interfaces, and rebinding one stops ADB from seeing the tablet until it is undone. The flasher will not open Zadig unless the Loader is actually present.
4. **Apply the liberation patches** and, if needed, wipe and reboot the unit.
5. **If it wiped the unit, ask you to join it to Wi-Fi.** When the Mabu's screen comes up, connect it to your Wi-Fi network by touching the screen, then continue. Installs run over Wi-Fi from here.
6. **Install the apps** (F-Droid app store, the Lawnchair home screen, and Mabu Factory Mode), **patch the motor-access policy, reboot, and run a self-check.**

When it's done you'll see a **`Done`** banner and a **self-test summary** (passed / failed / warnings). If anything fails, it stops with a message explaining what went wrong.

> **If a step fails, don't retry just that step.** Power the Mabu fully off and start the flash again from the top; it's designed to be re-run safely, and it skips work that's already done.

---

## Troubleshooting
**The PC can't see the Mabu at all?** Start here. This read-only diagnostic reports which driver is bound to each Rockchip USB ID and what's missing. It changes nothing:
```powershell
.\scripts\diagnose-usb.ps1 -Watch
```
`-Watch` polls for about 30 seconds, so you can start it first and *then* power the unit on; it catches the roughly 10-second Loader window instead of you racing it.

| Symptom | Fix |
|---|---|
| `execution of scripts is disabled` | Run `Set-ExecutionPolicy RemoteSigned -Scope CurrentUser`, then try again. If you used the ZIP, also run `Get-ChildItem -Recurse -Filter *.ps1 \| Unblock-File` |
| Script says it must run as Administrator | Reopen PowerShell via right-click Start button → *Terminal (Admin)* |
| SmartScreen blocks `MabuFlashSetup.exe` | Click **More info**, then **Run anyway**. The installer isn't code-signed yet |
| Script says `adb.exe not found` | Let it auto-install, or run `winget install Google.PlatformTools` and restart PowerShell |
| `rkdeveloptool.exe not found` | You're running from the wrong folder, or the download was incomplete. Run `.\scripts\install-tools.ps1` from the folder containing `scripts\` |
| Loader never appears | Boot the tablet **while holding ADKEY** (pin 4 to GND) with the flash already running. If it still doesn't catch, reboot to Android, replug the harness USB, and listen for the Windows **"new USB device" chime**: **no chime = hardware** (check connections and the USB cable, see wiring below); **chime = retry** the ADKEY boot |
| Windows shows the Mabu (as "H7R", "ADB Interface" or "MTP") but you get `No adb device and no Loader` | Zadig was pointed at the Android-mode device at some point, which stops ADB from seeing it. The flasher detects this and repairs it in place, so run it again first. If it still reports the misbinding, follow the undo steps it prints |
| Stuck at the Wi-Fi step | Touch the Mabu's screen and join it to your Wi-Fi, then continue; it picks up automatically once the Mabu is online |
| The motor fix "needs the WSL reflash fallback" | This only happens on the rare unit whose policy patch changes size. Run `.\scripts\install-tools.ps1 -InstallWsl` as Administrator to install WSL/Ubuntu (restart if asked), then re-run the flash with `-NoWipe` |
| App installs fail | Make sure the Mabu and the PC are on the same Wi-Fi network |
| "device descriptor request failed" | The D+ and D- wires are swapped; see the wiring note below |

---

## Harness Wiring
The harness uses a 30-pin IDC ribbon cable (2.0 mm pitch); pin 1 is at the GND/USB end, marked by the red stripe. On the PC end, wire a USB-A connector and an ADKEY switch as shown.

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
- If you see "device descriptor request failed", the D+ and D- wires are reversed; swap them.

---

## More Documentation
- **Detailed walkthrough**: background on each phase, the full 30-pin header pin-out, recovery for unusual unit states, and the permanent SELinux fix: [FLASH-A-NEW-MABU.md](FLASH-A-NEW-MABU.md).
- **The GUI edition**: design, the UI contract shared by both front-ends, threading model, and build steps: [app/EXECUTABLE.md](app/EXECUTABLE.md).

---

Copyright (C) 2026 Get Circuit Bent LLC. Licensed under the [GNU General Public License v3.0](LICENSE). Contact: info@getcircuitbent.com
