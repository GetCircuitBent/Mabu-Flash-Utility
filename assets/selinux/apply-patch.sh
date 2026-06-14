#!/usr/bin/env bash
# apply-patch.sh
#
# REFERENCE ONLY — this script documents the WSL inspection tooling and stops
# short of a turnkey binary-policy merge. It does NOT complete the injection on
# this device. The Mabu is a non-root `user` build: /system cannot be remounted
# rw from adb, so the `mount -o rw,remount /system` + `adb push` steps printed
# below apply ONLY to a rooted/AOSP device. For the real unit, use the
# magiskpolicy on-device flow in the main guide §6 Tier 2, then flash the
# patched precompiled_sepolicy back via the Rockchip Loader.
#
# Patches the Mabu system SELinux policy to grant the face-tracking app
# direct access to /dev/ttyS1.
#
# Prerequisites (Ubuntu/WSL):
#   sudo apt-get install setools policycoreutils adb
#
# Usage:
#   ./apply-patch.sh <device-ip>   e.g.  ./apply-patch.sh 192.168.0.180
#
# What it does:
#   1. Pulls the running SELinux policy from the device
#   2. Compiles a supplemental policy module with our rule
#   3. Merges it into the pulled policy using seinfo/audit2allow tooling
#   4. Pushes the patched policy to /system/etc/selinux/precompiled_sepolicy
#      (requires USB -- WiFi ADB cannot remount /system)

set -euo pipefail

DEVICE_IP="${1:-192.168.0.180}"
ADB="adb -s ${DEVICE_IP}:5555"
WORK="$(mktemp -d)"
RULE="allow untrusted_app serial_device:chr_file { open read write getattr ioctl };"

echo "==> Pulling running policy from device..."
$ADB pull /sys/fs/selinux/policy "$WORK/policy.bin"

echo "==> Converting to CIL using sepolicy-analyze..."
# audit2allow needs the binary policy and a fake denial to generate the module
echo "avc: denied { open } for scontext=u:r:untrusted_app:s0 tcontext=u:object_r:serial_device:s0 tclass=chr_file" \
    | audit2allow -p "$WORK/policy.bin" -M mabu_serial -o "$WORK/"

echo "==> Generated mabu_serial.pp -- installing module into policy binary..."
# semodule_link + semodule_expand would be the clean path, but for Android
# monolithic policies we patch the CIL layer instead.
# For a full procedure, compile from AOSP source with the .te file added to
# the device-specific sepolicy directory and rebuild with `m sepolicy`.

echo ""
echo "NOTE: Full automated patching of Android monolithic binary policies"
echo "requires AOSP build environment. The recommended path is:"
echo ""
echo "  1. Add mabu_serial_access.te to your device sepolicy directory"
echo "     (system/sepolicy/private/ or device/<vendor>/<board>/sepolicy/)"
echo "  2. Rebuild: m sepolicy"
echo "  3. Flash: adb shell mount -o rw,remount /system"
echo "            adb push out/target/product/<board>/system/etc/selinux/precompiled_sepolicy"
echo "                       /system/etc/selinux/precompiled_sepolicy"
echo "            adb reboot"
echo ""
echo "Alternatively, with a rooted shell:"
echo "  setenforce 0    (permissive mode -- temporary, resets on reboot)"
echo ""
echo "Policy rule to add:"
echo "  $RULE"

rm -rf "$WORK"
