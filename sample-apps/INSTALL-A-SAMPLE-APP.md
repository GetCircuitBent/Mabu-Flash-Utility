# Install a Sample App

You have just freed a Mabu with the [Mabu Flash Utility](../README.md). This page
puts an app on it, so it does something.

You do **not** need to be an Android developer, and you do not need to build
anything. Each sample ships a ready-made `.apk` file: you download it, send it to
the Mabu over your Wi-Fi network, and it runs. Budget about **ten minutes** the
first time, most of that finding the tablet's IP address.

If you would rather build from source and change the code, skip to
[Building It Yourself](#building-it-yourself) instead.

---

## The Apps

| App | What it does | Status |
|---|---|---|
| [**Signboard**](01-signboard/) | Mabu as a living sign. A picture or looping animation on the screen while the body keeps moving on its own. Start here. | Tested on real hardware |
| [**Theremin**](02-theremin/) | The camera watches your hands and turns them into sound, while the robot follows your face. | Built, not yet tested on hardware, **no APK published yet** — build it from source for now |

---

## What You'll Need

- **A flashed Mabu.** A factory unit will refuse the install; its app installation
  is locked and its debug access is switched off. Run the flash first.
- **Your PC and the Mabu on the same Wi-Fi network.** This is how the app gets
  across. If your router has "client isolation" or "guest network" turned on for
  that network, the two cannot see each other, so use your normal network.
- **The Mabu powered on**, with its home screen up.

You will type a few commands. That is unavoidable: the Mabu has no app store
front end and no external USB port, so a PC command is the only way to hand it a
file. Every command you need is written out below; you can copy and paste them.

---

## Step 1: Open a Command Window with `adb` in It

`adb` is the tool that talks to Android devices. The flash installed it for you,
so usually it is already there.

Press **Start**, type `powershell`, open **Windows PowerShell**, and check:

```powershell
adb version
```

**If that prints a version number, you are done with this step.** Skip to step 2.

**If it says `adb` is not recognised**, it is installed but not on this window's
search path. Paste this line, which looks in the three places the flasher can put
it and makes it available for the rest of this window:

```powershell
$f = Get-ChildItem "$env:LOCALAPPDATA\MabuFlash","$env:LOCALAPPDATA\Microsoft\WinGet\Packages","C:\Mabu-Flash-Utility\tools" -Recurse -Filter adb.exe -ErrorAction SilentlyContinue | Select-Object -First 1; if ($f) { $env:Path += ';' + $f.DirectoryName; "Using $($f.FullName)" } else { "Not found - see below" }
```

Then run `adb version` again.

> **If it still is not found**, adb was never installed on this PC. Install it
> and reopen PowerShell:
> ```powershell
> winget install Google.PlatformTools
> ```

That `$env:Path` line lasts only as long as the window you typed it in, on
purpose: it changes nothing permanent on your PC. If you close PowerShell and
come back, run it again.

> The third path in that line assumes you unzipped the scripts to
> `C:\Mabu-Flash-Utility`. If you put them somewhere else, change it to match, or
> just use the `winget` command above.

---

## Step 2: Find the Mabu's IP Address

An IP address is the Mabu's number on your Wi-Fi network. It looks like
`192.168.0.180`. You need it to send the app.

Three ways to get it, easiest first:

1. **Read it off the end of the flash.** The flasher prints it in the summary when
   it finishes. If your PowerShell window from the flash is still open, scroll up.
2. **Look in your router.** Open your router's admin page in a browser and find
   the list of connected devices (often called *DHCP clients*, *Attached Devices*
   or similar). The Mabu reports its model name, **`H7R`**, so that is what to
   look for. Some routers show only a MAC address and no name, in which case use
   method 1 or 3.
3. **Ask the network.** In PowerShell:
   ```powershell
   arp -a | Select-String '192.168'
   ```
   This lists everything your PC has recently talked to. If you cannot tell which
   line is the Mabu, use method 1 or 2.

Write the address down. Everywhere below that shows `192.168.0.180`, put your own
number in instead.

---

## Step 3: Connect to the Mabu

```powershell
adb connect 192.168.0.180:5555
adb devices
```

`adb devices` should list your address followed by the word **`device`**. That
means you are connected and can carry on.

| What you see instead | What it means |
|---|---|
| `unauthorized` | The unit is not fully flashed. Run the flasher again; a properly flashed Mabu never asks permission. |
| `failed to connect` / `cannot connect` | Either the address is wrong, or the Mabu is not on this Wi-Fi network. Recheck step 2, and check the Mabu's own Wi-Fi settings on its screen. |
| `offline` | Run `adb disconnect` and then `adb connect` again. |
| Nothing listed at all | See [If the Mabu won't connect](#if-the-mabu-wont-connect) at the bottom. |

The connection drops from time to time, usually when the screen sleeps or the
robot moves and loses signal. That is normal. Just run the two commands again.

---

## Step 4: Download the App

Go to the [latest release](https://github.com/GetCircuitBent/Mabu-Flash-Utility/releases/latest)
and download the `.apk` file for the app you want:

| App | File | Size |
|---|---|---|
| Signboard | `mabu-signboard.apk` | about 3 MB |
| Theremin | `mabu-theremin.apk` | not published yet |

Save it somewhere you can find it, like your **Downloads** folder. That one file
is all you need.

There is a matching `.sha256` file next to it. You can ignore it; it is there so
you can confirm the download is intact if you want to:

```powershell
Get-FileHash "$env:USERPROFILE\Downloads\mabu-signboard.apk" -Algorithm SHA256
```

The number it prints should match the contents of the `.sha256` file.

> Your browser may warn that `.apk` files can harm your device, because it is an
> Android app arriving outside an app store. That warning is generic. Keep the
> file; it came from the release page linked above.

---

## Step 5: Install It

Replace the path below with wherever your file actually landed.

```powershell
adb install -r "$env:USERPROFILE\Downloads\mabu-signboard.apk"
```

It takes a few seconds and prints **`Success`**.

> **If it prints `INSTALL_FAILED_UPDATE_INCOMPATIBLE`**, an older copy of the app
> is already on the Mabu. Remove it and install again:
> `adb uninstall com.getcircuitbent.mabu.signboard`

---

## Step 6: Give It Permission and Start It

Android will not let an app use the camera, the microphone or the storage card
until it is allowed to. Normally the app asks you on screen; here we grant it up
front, so nothing interrupts the robot.

**For Signboard:**

```powershell
adb shell pm grant com.getcircuitbent.mabu.signboard android.permission.READ_EXTERNAL_STORAGE
adb shell mkdir -p /sdcard/signboard
adb shell am force-stop com.catalia.factorymode
adb shell am start -n com.getcircuitbent.mabu.signboard/.MainActivity
```

**For Theremin:**

```powershell
adb shell pm grant com.getcircuitbent.mabu.theremin android.permission.CAMERA
adb shell pm grant com.getcircuitbent.mabu.theremin android.permission.READ_EXTERNAL_STORAGE
adb shell mkdir -p /sdcard/theremin
adb shell am force-stop com.catalia.factorymode
adb shell am start -n com.getcircuitbent.mabu.theremin/.MainActivity
```

The app appears on the Mabu's screen and the robot starts moving.

That `force-stop com.catalia.factorymode` line matters. Only one app at a time is
allowed to drive the motors, and the factory app that ships on every unit starts
itself at boot and holds them. Stopping it hands the motors over. You need this
line **after every power-on**, not just the first time.

From now on you can also just tap the app's icon on the Mabu's home screen,
though if the motors do not move, run the force-stop line above and restart it.

---

## Rules That Keep Your Mabu Working

Two of these have cost real units real downtime. They are short; please read
them.

1. **Never run `adb reboot`.** Units have come back from it with no Wi-Fi. Since
   the Mabu has no external USB port and no buttons, that means no way back in
   without opening the case. If you need to restart it, switch the power off and
   on by hand.

2. **Only one app drives the motors at a time.** If you install a second sample,
   stop the first one before starting it:
   `adb shell am force-stop com.getcircuitbent.mabu.signboard`.

3. **If the robot does not move, push its head gently with a finger.** *Limp*
   means the motor board has no power, which is a wiring fault and no app will
   fix it. *Stiff* means the board is fine and the app just has not taken the
   motors, so use the force-stop line in step 6 and start the app again.

---

## Making It Yours

You do not have to write any code to change what the samples show.

**Signboard** displays any PNG, JPEG, WebP or animated GIF. Send it one:

```powershell
adb push "$env:USERPROFILE\Pictures\mysign.gif" /sdcard/signboard/
```

Then tap **From /sdcard** on the app's screen. Tapping it again cycles through
everything you have sent. The screen is **1024 x 600**; make your image that size
to fill it exactly.

**Theremin** plays any 16-bit WAV file:

```powershell
adb push "$env:USERPROFILE\Music\mysample.wav" /sdcard/theremin/
```

Each app's own page — [Signboard](01-signboard/README.md),
[Theremin](02-theremin/README.md) — covers everything else on its screen.

---

## If Something Goes Wrong

| What you see | What to do |
|---|---|
| `adb: command not found` or `not recognised` | Redo step 1. The `$env:Path` line only lasts for one PowerShell window. |
| `adb devices` shows nothing | See [below](#if-the-mabu-wont-connect). |
| `device unauthorized` | The unit is not fully flashed. Re-run the flasher. |
| `INSTALL_FAILED_OLDER_SDK` | Wrong APK. Download it from the release page linked in step 4, not from elsewhere. |
| App opens but nothing moves | The factory app still holds the motors. Run the `force-stop com.catalia.factorymode` line from step 6, then start the app again. |
| App opens, nothing moves, head is **limp** | Motor board has no power. That is hardware, not software. |
| Screen is black but the app is running | For Signboard, double-tap the screen to leave full-screen mode. |
| Connection drops mid-use | Normal. `adb disconnect`, then `adb connect` again. |

### If the Mabu Won't Connect

Work through these in order:

1. **Check the Mabu is actually on Wi-Fi.** On its screen, open Settings and look
   at the Wi-Fi entry. If it is not joined to your network, join it there.
2. **Check it is the same network as your PC**, not a guest network and not the
   5 GHz half of a split network your PC is not on.
3. **Confirm the IP address.** DHCP addresses change. If the Mabu has been off
   for a while, it may have a different one now. Redo step 2.
4. **Wake the listener.** Occasionally the Mabu stops listening for connections,
   most often after a data wipe. Fixing it needs the USB programming harness:
   plug it in as you did for the flash, then run
   ```powershell
   adb tcpip 5555
   adb shell setprop persist.adb.tcp.port 5555
   ```
   That makes it stick across power cycles.

---

## Building It Yourself

Everything above installs the app as shipped. If you want to change the code, you
need an Android build environment; the developer path is documented in
[Getting Started](SAMPLE-APP-FUNCTION-INDEX.md#getting-started) in the Sample App
Function Index, which covers the toolchain, the four build settings that matter
on this hardware, and each sample's `install.ps1` (build, install, launch and
tail the logs in one command).

The apps are deliberately written to be read and copied. Both READMEs walk
through their source file by file.

---

Copyright (C) 2026 Get Circuit Bent LLC. Licensed under the
[GNU General Public License v3.0](../LICENSE).
Contact: info@getcircuitbent.com
