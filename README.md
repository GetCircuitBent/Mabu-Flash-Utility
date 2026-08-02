# Mabu Flash Utility

This repo frees a **Mabu** robot tablet from its factory software lock, installs a normal home screen and app store, and unlocks access to its motors — so you can install and run your own apps. One script does the whole job — `flash.ps1`. It auto-detects the unit's state, applies everything it needs, and stops with a clear message the moment anything goes wrong.

A flash takes about **15 minutes** on a PC that has done it before, and about **30 minutes** the first time (most of that is the one-time setup).

> **New to this?** You only need to follow three sections below, in order: **Download**, **One-Time Setup**, then **Flash a Mabu**. Everything else is reference.

---

## What You'll Need

### Hardware
- A Mabu unit
- The **USB programming harness** — a 30-pin ribbon cable that plugs into the header inside the Mabu, ending in a USB-A plug and an **ADKEY** button. This is the only way to talk to the Mabu; there's no external USB port on the device. (Wiring diagram is at the bottom of this page.)

### PC
- **Windows 10 or 11**
- An **internet connection** (to download tools and apps)
- A **WiFi network the Mabu can join.** Partway through, the Mabu boots up and the flash finishes over WiFi — you'll join it to your network on its own touchscreen when prompted.

---

## Download

**Option A — ZIP (no extra software needed):**
1. Click the green **Code** button at the top of this page.
2. Click **Download ZIP**.
3. Unzip it to a **permanent location** (e.g. `C:\Mabu-Flash-Utility`). The scripts run from that folder, so don't put it in Downloads or a temp folder.

**Option B — Git** (if you already have Git):
```
git clone https://github.com/GetCircuitBent/Mabu-Flash-Utility.git
```

---

## One-Time Setup

Do this **once per PC**. It installs the flashing tools and the USB drivers the Mabu needs.

Open **PowerShell as Administrator** (right-click the Start button → **Terminal (Admin)** or **Windows PowerShell (Admin)**) for all of the steps below — and keep this same window open for the flash itself.

### 1. Allow the scripts to run
Windows blocks downloaded scripts by default. Run this once:
```powershell
Set-ExecutionPolicy RemoteSigned -Scope CurrentUser
```

### 2. Run the setup script
Move into the folder you unzipped (replace the path with wherever you put it), then run:
```powershell
cd "C:\Mabu-Flash-Utility"
.\scripts\install-tools.ps1
```
This sets up the Rockchip flashing tool and the Zadig USB helper. When it finishes, the core checks should read **`[OK]`**.

> **About WSL (optional):** the setup script also offers to install WSL/Ubuntu. The flash **does not need it** for the normal case — it patches the motor policy right on the Mabu. WSL is only used as an automatic fallback on the rare unit where that patch needs a full re-flash. If you'd rather not install it now, you can skip it; the flash will tell you if it ever needs it. If setup does install WSL, it will ask you to **restart the PC**, then run `.\scripts\install-tools.ps1` once more.

### 3. Install the Android USB driver
```powershell
.\scripts\install-android-driver.ps1
```
This prepares the Android USB driver and prints the exact **Device Manager** clicks to install it. Follow those on-screen steps.

That's it — you won't need to repeat setup on this PC.

---

## Flash a Mabu

### Step 1 — Connect the harness
Plug the USB harness into the Mabu's internal header and into a USB port on your PC. **Use the same USB port every time** — the driver is tied to the port, and switching ports means redoing the Zadig step once.

### Step 2 — Power on the Mabu
Turn the unit on and let it boot to its normal screen. The script talks to the Mabu over the harness to work out what state it's in.

### Step 3 — Run the script
In the same **Administrator** PowerShell window, from the repo folder:
```powershell
.\scripts\flash.ps1
```
That's the whole command — no options needed. (Running it as Administrator lets it clean up the USB connection and install the driver automatically.)

### Step 4 — Follow the on-screen prompts
The script drives the whole process and tells you exactly what to do when it needs you. In order, it will:

1. **Figure out the unit automatically** and decide whether a data wipe is needed (a factory-locked unit gets wiped; an already-freed one doesn't).
2. **(First PC only) Launch Zadig** to install the USB driver. When Zadig opens: **Options → List All Devices**, pick the device with **USB ID `2207 320A`**, set the driver to **WinUSB**, and click **Replace Driver**. Switch back to PowerShell and press Enter. This happens only once per PC.
3. **Apply the liberation patches** and, if needed, wipe and reboot the unit.
4. **If it wiped the unit, ask you to join it to WiFi.** When the Mabu's screen comes up, connect it to your WiFi network by touching the screen, then press Enter. Installs run over WiFi from here.
5. **Install the apps** (F-Droid app store, the Lawnchair home screen, and Mabu Factory Mode), **patch the motor-access policy, reboot, and run a self-check.**

When it's done you'll see a **`Done`** banner and a **self-test summary** (passed / failed / warnings). If anything fails, the script stops with a red message explaining what went wrong.

> **If a step fails, don't retry just that step.** Power the Mabu fully off and run `flash.ps1` again from the top — it's designed to be re-run safely, and it skips work that's already done.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| `execution of scripts is disabled` | Run `Set-ExecutionPolicy RemoteSigned -Scope CurrentUser`, then try again. |
| Loader never appears after power-on | Make sure the harness is plugged in **before** you power on. Try pressing/holding ADKEY as you power on. Check the D+/D- wires (see wiring below). |
| Script says `adb.exe not found` | Let it auto-install, or run `winget install Google.PlatformTools` and restart PowerShell. |
| Stuck at the WiFi step | Touch the Mabu's screen and join it to your WiFi, then press Enter — the script picks up automatically once the Mabu is online. |
| Script says the motor fix "needs the WSL reflash fallback" | This only happens on the rare unit whose policy patch changes size. Run `.\scripts\install-tools.ps1` as Administrator to install WSL/Ubuntu (restart if asked), then re-run the flash with `-NoWipe`. |
| "device descriptor request failed" | The D+ and D- wires are swapped — see the wiring note below. |

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
- If you see "device descriptor request failed", the D+ and D- wires are reversed — swap them.

---

## More Documentation

- **Detailed walkthrough** — background on each phase, the full 30-pin header pin-out, recovery for unusual unit states, and the permanent SELinux fix: [FLASH-A-NEW-MABU.md](FLASH-A-NEW-MABU.md).
- **GUI version** — a double-clickable graphical version of this flasher is in progress under `app/`. It will be added here as a second, no-PowerShell option once it's finished.
