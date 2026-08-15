# MabuFlash: Executable / GUI Edition
This branch turns the console flash utility into a packaged, GUI-driven `.exe`, while `main` stays the known-good console tool.

## Design: One Core, Two Front-Ends (Option B)
The proven flash logic is refactored to talk to an injected **UI provider** instead of calling `Write-Host` / `Read-Host` directly. Both front-ends implement the same contract, so the logic runs identically either way.

```
        +---------------------------+
        |  MabuFlashCore.ps1        |   the phased flash logic (UI-agnostic)
        |  (adapted flash-mabu.ps1) |   calls $Ui.Section/Log/Flash/Prompt/...
        +-------------+-------------+
                      |
         implements the UI contract
            /                     \
  +------------------+      +------------------+
  | Console provider |      |  WPF GUI         |
  | (behaviour ==    |      |  provider        |
  |  known-good)     |      |  (2 progress     |
  +------------------+      |   bars + prompts)|
                           +------------------+
```

### The UI Contract
A UI provider is a hashtable of scriptblocks:

| Member                          | Purpose                                             |
|---------------------------------|-----------------------------------------------------|
| `Section($name)`                | Start a phase (advances the Flashing bar by weight) |
| `Log($sev,$msg)`                | Log line; `$sev` = info \| ok \| warn \| fail       |
| `Flash($pct,$label)`            | Set Flashing bar (0–100)                             |
| `Validate($pct,$label)`         | Set Validating bar (0–100)                           |
| `Prompt($title,$body,$buttons)` | Blocking prompt → returns chosen button text        |
| `Done($ok,$summary)`            | Terminal state                                       |

`Read-Host` pauses (Zadig rebind, Wi-Fi setup) become `Prompt(...)`. `Section/Ok/Warn/Fail` map onto `Section` + `Log`.

### The Two Bars
- **Flashing** = everything that changes the device: Loader, patches, wipe, reset, app installs, SELinux. Each `Section` bumps the bar by a fixed weight (see `$FlashWeights` in the core).
- **Validating** = the self-test (Phase 8); advances one notch per check.

### Human-in-the-Loop Stops (Unavoidable, Surfaced as Prompts)
The device flow can't be fully hands-off. These become prompt cards:

1. **Connect / catch Loader**: hold ADKEY through power-on (physical). Only needed when ADB is unavailable; from a booted unit the core enters Loader over ADB itself.
2. **Zadig WinUSB rebind**: one-time-per-USB-port, needs admin. `Confirm-LoaderWinUsb` now aborts rather than prompting when `2207 320A` is absent from the bus, so this stop never appears with only the Android-mode interfaces to choose from.
3. **Wi-Fi setup on tablet**: after a `/data` wipe, creds are gone.

The Android ADB driver is no longer one of these stops. When the core finds the adb interface bound to something adb cannot see through (a Zadig binding on the Android-mode device), `Repair-MabuAdbBinding` registers the ADB device-interface GUID on it and restarts the node, then the flash continues. It falls back to a prompt-free failure message with manual steps only if that does not take.

## Files
Project layout:

| Path                        | Status | Purpose                                              |
|-----------------------------|--------|------------------------------------------------------|
| `app/MabuFlashGui.ps1`      | done   | WPF front-end; `-Simulate` fakes it, else real flash |
| `app/lib/MabuUi.ps1`        | done   | UI contract + console provider (`New-ConsoleUi`)     |
| `app/lib/MabuFlashCore.ps1` | done   | UI-agnostic flash logic (`Invoke-MabuFlash`)         |
| `app/build/build-exe.ps1`   | done   | ps2exe packaging (requireAdmin + STA); builds app/MabuFlash.exe |
| `scripts/flash-mabu.ps1`    | source | the merged console flasher the core mirrors          |

## Threading Model (GUI)
WPF runs its message pump on the main thread (`ShowDialog`). The flash logic is long-running and blocking (ADB, sleeps), so it runs in a **background runspace**. The worker only enqueues plain-data messages onto a synchronized queue; a `DispatcherTimer` on the UI thread drains the queue and does every UI mutation, so there is no cross-runspace scriptblock hazard. Prompts block the worker on a `ManualResetEventSlim` that the button click (UI thread) signals. A `[hashtable]::Synchronized` bag (`$sync`) is shared by reference between threads.

## Build Order
The plan:

1. **[done]** GUI shell + simulated flow.
2. **[done]** Extract `MabuFlashCore.ps1` from the console flasher behind the UI contract. *(Re-based onto the merged `flash-mabu.ps1`: on-device magiskpolicy SELinux with WSL reflash fallback, Mabu factory mode on by default via `-SkipMabu`, admin-gated USB purge, repo-relative root.)*
3. **[done]** Console provider (`New-ConsoleUi`); the core defaults to it. Verify a console `Invoke-MabuFlash` run matches known-good on real hardware.
4. **[done]** Wire the GUI to the real core (drop `-Simulate` to flash for real). Child-script output now routes to the log via `Invoke-Child`. Needs an on-hardware run to confirm.
5. **[done]** `build-exe.ps1`: ps2exe with requireAdmin + STA manifest, optional icon/signing. Builds `app/MabuFlash.exe` in place (loads the repo payload from disk at runtime; the exe is gitignored). *Remaining: hardware validation, and optional code-signing cert.*

## Running the Shell (Today)
Simulated flow, no hardware or tools needed:

```powershell
# Simulated flow: no hardware, no tools needed. See the UX end-to-end.
powershell -ExecutionPolicy Bypass -File app\MabuFlashGui.ps1 -Simulate
```
