# Mabu Flash Procedure -- Source of Truth

> **Operator-validated 2026-08-14; first-time-PC route corrected 2026-08-18.
> This document is canonical.** Every other doc
> (README.md, FLASH-A-NEW-MABU.md, the GUI text, and all script messages) must
> agree with this. Where anything contradicts this file, this file wins and the
> other doc gets corrected.

## The procedure

1. **Launch the GUI and click Start Flashing.**

2. **Ask first: has this PC ever flashed a Mabu before?** The answer decides how
   you get into the Loader, and getting this backwards is the most common way to
   waste an hour.

### If this is the first time flashing a Mabu from this PC

**Boot the tablet normally into Android. Do not hold ADKEY.** Holding ADKEY
cannot work yet: catching the Loader depends on this PC's USB drivers, and on a
fresh PC they are not there. There is nothing to catch the Loader *with*.

- Boot the tablet into **Android** and join it to **Wi-Fi** on its own screen.
- The flasher walks you through installing the **Android USB driver** in Device
  Manager (see [Driver install](#driver-install-first-pc-only) below), then the
  **Zadig** rebind of PID 320A to WinUSB.
- With the driver in place the flasher reads the unit's state and enters the
  Loader **over adb** -- no timing to get right, nothing to hold.
- It then runs the whole flash, as in A below.

Both driver steps are once per PC (Zadig is once per PC *per USB port*). After
this, that PC is set up and the ADKEY route below becomes available.

### If this PC has flashed a Mabu before

3. **Boot the tablet while holding ADKEY.** Any way of booting works -- unplug and
   replug the harness, or use the power button. Hold ADKEY through the boot.

4. The flasher watches for the Rockchip **Loader (PID 320A)**. One of two things
   happens:

### A. Loader catches -> the script runs the whole flash on its own
- applies the liberation patches
- reboots the unit to Android
- pauses for you to **join Wi-Fi** on the tablet
- finishes the app installs **over Wi-Fi**
- runs the **self-tests**
- **re-runs automatically if any test fails**

### B. Loader does NOT catch -> diagnose the USB link
- Let the tablet finish booting to **Android**. **If it lands on the recovery
  screen ("No command") instead, reboot it to Android** and continue from here --
  the test is the same.
- Unplug and replug the harness USB and listen for the Windows **"new USB device"
  chime**.
  - **No sound -> it is a hardware problem.** The data link is not there. Tell the
    user to check the harness connections and the USB cable, and fix that before
    retrying.
  - **Sound present -> the link is fine, the Loader window was just missed.** Retry
    from step 3 (boot while holding ADKEY).

## Driver install (first PC only)

Installing the Android USB driver is a Device Manager click-through; the flasher
patches Google's `android_winusb.inf` first, to add the hardware ID your unit
actually reports, and tells you which node to bind.

**Windows may refuse it outright**, with *"The third-party INF does not contain
digital signature information"* (`0xE0000247`) and **no** "install anyway" button.
That is driver signature enforcement: patching the INF invalidates Google's
catalog signature, so there is nothing left for Windows to verify. Turn
enforcement off for one boot:

1. Hold **Shift**, click **Start > Power > Restart**
2. **Troubleshoot > Advanced options > Startup Settings > Restart**
3. Press **7** (Disable driver signature enforcement)
4. Run the flash again and repeat the driver step

It reverts on the next normal boot and the driver stays installed: only the INF
was unsigned, and the driver it points at (Microsoft's in-box WinUSB) is signed,
so enforcement gates the install only. `bcdedit /set testsigning on` is **not**
the fix -- it permits test-*signed* drivers, which this is not, and it is
permanent rather than a one-off.

## Notes for keeping other docs honest
- **Booting to Android is the first-time-on-this-PC route, not a shortcut.** Do
  not describe it as "quicker", "easier", or an alternative for people who
  already have adb. On a fresh PC it is the *only* way in, because holding ADKEY
  cannot catch a Loader this PC has no driver for.
- Once a PC is set up, Loader entry is **boot-while-holding-ADKEY**, caught by
  the flasher. Those are the two ways in; do not document a third.
- The **"new USB device" chime after replug** is the definitive test for whether
  the physical USB link works. Use it to split a genuine hardware fault from a
  missed Loader catch -- do not guess at drivers, ports, hubs, or ghost nodes for
  a link that has never made the sound.
- The recovery "No command" screen is **not** a failure state to debug -- just
  reboot to Android and run the chime test from there.
