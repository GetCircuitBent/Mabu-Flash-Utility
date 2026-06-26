# rkdeveloptool (auto-managed by scripts\install-tools.ps1)

Source:  https://github.com/cpebit/rkdeveloptool-bin
Pin:     c23f0f5d04f329a1d40b42537983565698a02865
Files:   rkdeveloptool.exe, libusb-1.0.dll, msvcp140.dll, vcruntime140.dll
Hashes:  see $RkdevManifest in scripts\install-tools.ps1

This is a third-party Windows build of upstream
https://github.com/rockchip-linux/rkdeveloptool. The pin is fixed in
the install script; bytes are verified against the embedded SHA-256
manifest after download. To upgrade the pin, change $RkdevCommit and
the corresponding hashes in scripts\install-tools.ps1.

To rebuild from source instead, see option (A) in the project README.
