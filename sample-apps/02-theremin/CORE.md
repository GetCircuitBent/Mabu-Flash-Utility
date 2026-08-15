# Core Files Shared With Sample App 1

These files are copied **verbatim** from
[`../01-signboard`](../01-signboard/), with one mechanical difference: the
package name, and the JNI symbol names that follow from it.

| File | |
|---|---|
| `app/src/main/cpp/serial.c` | JNI symbols renamed to match the package |
| `app/src/main/cpp/CMakeLists.txt` | library renamed to `mabutheremin` |
| `app/src/main/java/.../SerialPort.kt` | |
| `app/src/main/java/.../MabuProtocol.kt` | |
| `app/src/main/java/.../MotorLink.kt` | |
| `app/src/main/java/.../MotorTween.kt` | |
| `app/src/main/java/.../Poses.kt` | |
| `app/src/main/java/.../Gestures.kt` | |
| `app/src/main/java/.../IdleScene.kt` | |
| `app/src/main/java/.../DeviceInfo.kt` | |

**If you change one, change both.** There is no build-time check; this file is
the check.

## Why Copies and Not a Shared Module

Because every sample has to build after being dragged out of the repo on its
own. Somebody who wants the Theremin should be able to copy
`sample-apps/02-theremin/` to their desktop, open it in Android Studio, and
press Run - with no parent project, no `include(":mabu-core")`, and nothing to
resolve outside the folder.

That property is worth more than avoiding the duplication. These files are the
deliverable of app 1; being copyable is the point of them, and a sample that
demonstrates copying them is more honest than one that hides them behind a
module boundary readers cannot see.

## Verifying They Are Still In Sync

From the repo root:

```powershell
$a = "sample-apps/01-signboard/app/src/main/java/com/getcircuitbent/mabu/signboard"
$b = "sample-apps/02-theremin/app/src/main/java/com/getcircuitbent/mabu/theremin"
foreach ($f in @('SerialPort.kt','MabuProtocol.kt','MotorLink.kt','MotorTween.kt','Poses.kt','Gestures.kt','IdleScene.kt','DeviceInfo.kt')) {
    $x = (Get-Content "$a/$f" -Raw) -replace 'signboard','theremin'
    $y = (Get-Content "$b/$f" -Raw)
    if ($x -ne $y) { Write-Host "DIFFERS: $f" -ForegroundColor Yellow }
}
```

Silence means they match.

## What Sample App 2 Adds On Top

Nothing in the list above is modified, so the motor behaviour is identical to
Signboard's. What changes is who writes the targets:

- `FaceFollow.kt` overwrites the eye and neck targets whenever a face is
  visible, running immediately after `IdleScene` on the same tick. Later
  writer wins, so the idle sweep only shows through when nobody is there.
- Blinks continue to come from `IdleScene` and `Gestures`, untouched, because
  a gesture claims the motors it uses and both writers respect that claim.

That is the whole integration. No mode flags, no state machine, nothing to
fall out of sync.
