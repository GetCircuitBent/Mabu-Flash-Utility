# Mabu Flash Procedure -- Source of Truth

> **Operator-validated 2026-08-14. This document is canonical.** Every other doc
> (README.md, FLASH-A-NEW-MABU.md, the GUI text, and all script messages) must
> agree with this. Where anything contradicts this file, this file wins and the
> other doc gets corrected.

## The procedure

1. **Launch the GUI and click Start Flash.**

2. **Boot the tablet while holding ADKEY.** Any way of booting works -- unplug and
   replug the harness, or use the power button. Hold ADKEY through the boot.

3. The flasher watches for the Rockchip **Loader (PID 320A)**. One of two things
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
    from step 2 (boot while holding ADKEY).

## Notes for keeping other docs honest
- Loader entry in this procedure is **boot-while-holding-ADKEY**, caught by the
  flasher. That is the whole method; do not document any other way in.
- The **"new USB device" chime after replug** is the definitive test for whether
  the physical USB link works. Use it to split a genuine hardware fault from a
  missed Loader catch -- do not guess at drivers, ports, hubs, or ghost nodes for
  a link that has never made the sound.
- The recovery "No command" screen is **not** a failure state to debug -- just
  reboot to Android and run the chime test from there.
