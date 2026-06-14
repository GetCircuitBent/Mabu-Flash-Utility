# Mabu Flash Guide

Step-by-step procedure for flashing a brand-new **Mabu** robot tablet (Catalia
Health H7R, Rockchip RK3288, Android 8.1, locked by Esper MDM) out of the box,
removing the lockdown, and installing your own apps — including the prepared
fix for the **SELinux issue** that otherwise blocks app access to the motors.

## Start here

- **[FLASH-A-NEW-MABU.md](FLASH-A-NEW-MABU.md)** — the full walkthrough.

## What's in this repo

| Path | What |
|---|---|
| `FLASH-A-NEW-MABU.md` | The complete flash procedure, Loader → liberation → apps → SELinux → calibration. |
| `assets/bridge/motor-bridge.sh` | Tier-1 SELinux workaround: shell-domain TCP→serial bridge the app talks to. |
| `assets/selinux/mabu_serial_access.te` | Tier-2 permanent fix: the single `allow untrusted_app serial_device` policy rule. |
| `assets/selinux/apply-patch.sh` | Reference procedure for applying the policy rule (see the guide for the magiskpolicy turnkey step). |
| `assets/selinux/selinux-README.md` | Background on the SELinux denial and both fix tiers. |

## Companion repos (not bundled here)

This guide drives, but does not duplicate, two sibling repos that are expected
to sit next to it (`../Mabu/`):

- **Mabu liberation toolkit** (`../Mabu/`) — the `flash-mabu.ps1` /
  `liberate-mabu.ps1` scripts, firmware patches, and notes.
- **Mabu-Facetrack** (`../Mabu/mabu-facetrack/`) — the face-tracking app the
  SELinux section is written around.

The `../Mabu/...` references in the guide resolve correctly when this folder is
checked out alongside the `Mabu` repo.

## The SELinux issue in one line

The liberation patch sets `androidboot.selinux=permissive`, but on this `user`
build Android `init` ignores it and re-enforces at boot (proven by runtime
`permissive=0` denials) — so installed apps can't open `/dev/ttyS1`. The guide
ships both a same-day workaround (TCP bridge) and a permanent policy fix.
