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

`Read-Host` pauses (Zadig rebind, WiFi setup) become `Prompt(...)`. `Section/Ok/Warn/Fail` map onto `Section` + `Log`.

### The Two Bars
- **Flashing** = everything that changes the device: Loader, patches, wipe, reset, app installs, SELinux. Each `Section` bumps the bar by a fixed weight (see `$FlashWeights` in the core).
- **Validating** = the self-test (Phase 8); advances one notch per check.

### Human-in-the-Loop Stops (Unavoidable, Surfaced as Prompts)
The device flow can't be fully hands-off. These become prompt cards:

1. **Connect / catch Loader**: hold ADKEY through power-on (physical).
2. **Zadig WinUSB rebind**: one-time-per-USB-port, needs admin.
3. **WiFi setup on tablet**: after a `/data` wipe, creds are gone.

## Files
Project layout:

| Path                        | Status      | Purpose                                     |
|-----------------------------|-------------|---------------------------------------------|
| `app/MabuFlashGui.ps1`      | in progress | WPF front-end; `-Simulate` runs a fake flow |
| `app/lib/MabuFlashCore.ps1` | TODO        | UI-agnostic flash logic (from flash-mabu)   |
| `app/lib/ConsoleUi.ps1`     | TODO        | Console provider (known-good behaviour)     |
| `app/build/build-exe.ps1`   | TODO        | ps2exe packaging + tool bundling            |
| `scripts/flash-mabu.ps1`    | source      | the console tool the core is extracted from |

## Threading Model (GUI)
WPF runs its message pump on the main thread (`ShowDialog`). The flash logic is long-running and blocking (ADB, sleeps), so it runs in a **background runspace**. The worker only enqueues plain-data messages onto a synchronized queue; a `DispatcherTimer` on the UI thread drains the queue and does every UI mutation, so there is no cross-runspace scriptblock hazard. Prompts block the worker on a `ManualResetEventSlim` that the button click (UI thread) signals. A `[hashtable]::Synchronized` bag (`$sync`) is shared by reference between threads.

## Build Order
The plan:

1. **[done]** GUI shell + simulated flow: see the UX before wiring logic.
2. **[next]** Extract `MabuFlashCore.ps1` from `flash-mabu.ps1` behind the UI contract.
3. `ConsoleUi.ps1` provider; verify the console run matches known-good on real hardware.
4. Wire the GUI provider to the real core; test on a unit.
5. `build-exe.ps1`: bundle rkdeveloptool/adb/magiskpolicy/APKs, UAC manifest, sign.

## Running the Shell (Today)
Simulated flow, no hardware or tools needed:

```powershell
# Simulated flow: no hardware, no tools needed. See the UX end-to-end.
powershell -ExecutionPolicy Bypass -File app\MabuFlashGui.ps1 -Simulate
```
