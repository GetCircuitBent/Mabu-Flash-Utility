<#
  MabuUi.ps1 -- the UI-provider contract shared by both front-ends.

  A UI provider is a hashtable of scriptblocks (see app/EXECUTABLE.md):
    Section($name)              start a phase
    Log($sev,$msg)              $sev = info | ok | warn | fail
    Flash($pct,$label)          set the Flashing bar (0-100)
    Validate($pct,$label)       set the Validating bar (0-100)
    Prompt($title,$body,$btns)  blocking; returns the chosen button text
    Done($ok,$summary)          terminal state

  The flash core (app/lib/MabuFlashCore.ps1) calls ONLY these, so the same
  logic drives the console or the WPF GUI unchanged.

  New-ConsoleUi returns a provider whose Section/Log output is byte-for-byte
  the known-good console format (the old Section/Info/Ok/Warn/Fail helpers), so
  a console run stays identical to scripts/flash.ps1. Flash/Validate are
  no-ops on the console (the console never had progress bars); Prompt maps to
  Read-Host.
#>

function New-ConsoleUi {
    <#
      Console provider. Behaviour-identical to the original console helpers:
        Section -> blank line + "==== name ====" in Cyan
        Log info/ok/warn/fail -> "  msg" in Gray/Green/Yellow/Red
    #>
    param()

    @{
        Section = {
            param($name)
            Write-Host "" -ForegroundColor Cyan
            Write-Host "==== $name ====" -ForegroundColor Cyan
        }
        Log = {
            param($sev, $msg)
            # Self-contained (the scriptblock is invoked after the factory
            # returns, so it can't close over an outer variable here).
            $col = @{ info = 'Gray'; ok = 'Green'; warn = 'Yellow'; fail = 'Red' }[$sev]
            if (-not $col) { $col = 'Gray' }
            Write-Host "  $msg" -ForegroundColor $col
        }
        # The console has no progress bars; the phased Section headers already
        # convey progress, matching the original tool. Keep these as no-ops so
        # the core can call them unconditionally.
        Flash    = { param($pct, $label) }
        Validate = { param($pct, $label) }
        Prompt   = {
            param($title, $body, $buttons)
            Write-Host ""
            Write-Host $title -ForegroundColor Yellow
            if ($body) { Write-Host "  $body" -ForegroundColor Gray }
            $default = if ($buttons -and $buttons.Count) { $buttons[0] } else { 'OK' }
            $opts = if ($buttons) { $buttons -join ' / ' } else { 'Enter to continue' }
            $ans = Read-Host "  [$opts] (Enter = $default)"
            if (-not $ans) { return $default }
            # Match a button case-insensitively; fall back to the default.
            foreach ($b in $buttons) { if ($b -and $ans -ieq $b) { return $b } }
            foreach ($b in $buttons) { if ($b -and $b -imatch [regex]::Escape($ans)) { return $b } }
            return $default
        }
        Done = {
            param($ok, $summary)
            Write-Host ""
            if ($ok) { Write-Host "==== Done ====" -ForegroundColor Green }
            else     { Write-Host "==== Stopped ====" -ForegroundColor Red }
            if ($summary) { Write-Host "  $summary" -ForegroundColor $(if ($ok) { 'Green' } else { 'Red' }) }
        }
    }
}
