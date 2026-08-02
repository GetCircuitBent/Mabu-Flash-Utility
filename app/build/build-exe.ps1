# build-exe.ps1
#
# Package the MabuFlash WPF GUI (app\MabuFlashGui.ps1) into a double-clickable
# MabuFlash.exe using ps2exe.
#
# The exe is a thin launcher: it still loads the repo payload (app\lib\*,
# scripts\*, tools\*, firmware\*, apks\*, mabu-archive\*) from disk at runtime.
# So it is built to app\MabuFlash.exe INSIDE the repo and must stay there -- the
# GUI resolves the repo root as the parent of the exe's folder. It is not a
# standalone single-file bundle; ship the whole repo folder with the exe in it.
#
# Requires the ps2exe module (auto-installed for the current user if missing).
# Building does NOT need Administrator; RUNNING the exe does (it's built with a
# requireAdministrator manifest for the USB purge + Zadig + Loader writes).
#
# Usage:
#   .\app\build\build-exe.ps1                       # build app\MabuFlash.exe
#   .\app\build\build-exe.ps1 -KeepConsole          # keep a console for debugging
#   .\app\build\build-exe.ps1 -CertThumbprint <hex> # also Authenticode-sign it

[CmdletBinding()]
param(
    [string] $OutputFile,                 # default: <repo>\app\MabuFlash.exe
    [string] $IconFile,                   # optional .ico (auto-detected if omitted)
    [string] $Version = '1.0.0.0',
    [string] $CertThumbprint,             # optional signing cert in Cert:\CurrentUser\My
    [switch] $KeepConsole                 # debug: keep the console window (drops -noConsole)
)

$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$Gui      = Join-Path $RepoRoot 'app\MabuFlashGui.ps1'
if (-not $OutputFile) { $OutputFile = Join-Path $RepoRoot 'app\MabuFlash.exe' }

function Info($m) { Write-Host "  $m" -ForegroundColor Gray }
function Ok($m)   { Write-Host "  $m" -ForegroundColor Green }
function Warn($m) { Write-Host "  $m" -ForegroundColor Yellow }

Write-Host "`n==== Build MabuFlash.exe ====" -ForegroundColor Cyan

if (-not (Test-Path $Gui)) { throw "GUI source not found: $Gui" }

# 1. ps2exe module ----------------------------------------------------------
if (-not (Get-Module -ListAvailable -Name ps2exe)) {
    Info 'ps2exe not found -- installing for the current user (needs internet + PSGallery)...'
    try {
        if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Scope CurrentUser -Force | Out-Null
        }
        Install-Module -Name ps2exe -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
    } catch {
        throw "Could not auto-install ps2exe: $($_.Exception.Message)`n  Install it manually, then re-run:  Install-Module ps2exe -Scope CurrentUser"
    }
}
Import-Module ps2exe -ErrorAction Stop
Ok "ps2exe $((Get-Module ps2exe).Version) ready."

# 2. Sanity-check the runtime payload the exe will need ---------------------
$payload = @(
    'app\lib\MabuFlashCore.ps1',
    'app\lib\MabuUi.ps1',
    'tools\rkdeveloptool\rkdeveloptool.exe',
    'tools\magiskpolicy\magiskpolicy-armeabi-v7a',
    'scripts\liberate-mabu.ps1',
    'scripts\wipe-data-head.ps1',
    'scripts\dump-system-cycled.ps1',
    'apks\F-Droid.apk',
    'apks\Lawnchair.apk'
)
$missing = $payload | Where-Object { -not (Test-Path (Join-Path $RepoRoot $_)) }
if ($missing) {
    Warn 'These runtime files are missing from the repo -- the exe needs them when it flashes:'
    $missing | ForEach-Object { Warn "  - $_" }
    Warn '(Building anyway; fix before a real flash.)'
} else {
    Ok 'Runtime payload present (lib, tools, scripts, apks).'
}

# 3. Icon (optional, auto-detect) -------------------------------------------
if (-not $IconFile) {
    $ico = Get-ChildItem (Join-Path $RepoRoot 'app'), (Join-Path $RepoRoot 'assets') `
           -Filter *.ico -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($ico) { $IconFile = $ico.FullName; Info "Using icon: $IconFile" }
}

# 4. Compile ----------------------------------------------------------------
$opts = @{
    inputFile    = $Gui
    outputFile   = $OutputFile
    title        = 'MabuFlash'
    description  = 'Mabu Flash Utility'
    product      = 'Mabu Flash Utility'
    company      = 'Get Circuit Bent'
    version      = $Version
    requireAdmin = $true      # UAC: USB purge, Zadig, Loader writes need admin
    STA          = $true      # WPF requires a single-threaded apartment
}
if (-not $KeepConsole) { $opts.noConsole = $true }
if ($IconFile)         { $opts.iconFile  = $IconFile }

# A running MabuFlash.exe locks the file, so ps2exe can't overwrite it. Detect
# that up front (a stale success is worse than a clear failure).
$before = if (Test-Path $OutputFile) { (Get-Item $OutputFile).LastWriteTime } else { [datetime]::MinValue }
Remove-Item $OutputFile -Force -ErrorAction SilentlyContinue
if (Test-Path $OutputFile) {
    $proc = Get-Process -Name ([IO.Path]::GetFileNameWithoutExtension($OutputFile)) -ErrorAction SilentlyContinue
    $hint = if ($proc) { " It is running (PID $($proc.Id -join ', ')) -- close the MabuFlash window, then re-run." }
            else       { ' Close whatever has it open, then re-run.' }
    throw "Cannot overwrite $OutputFile -- the file is locked.$hint"
}
Info "Compiling -> $OutputFile"
Invoke-ps2exe @opts
if (-not (Test-Path $OutputFile) -or (Get-Item $OutputFile).LastWriteTime -le $before) {
    throw 'ps2exe did not produce a fresh exe (compile failed or the output was locked). See the output above.'
}

# 5. Optional Authenticode signing ------------------------------------------
if ($CertThumbprint) {
    $cert = Get-Item "Cert:\CurrentUser\My\$CertThumbprint" -ErrorAction Stop
    $sig  = Set-AuthenticodeSignature -FilePath $OutputFile -Certificate $cert `
            -TimestampServer 'http://timestamp.digicert.com'
    if ($sig.Status -ne 'Valid') { Warn "Signing status: $($sig.Status) - $($sig.StatusMessage)" }
    else { Ok "Signed with $($cert.Subject)" }
}

# 6. Report -----------------------------------------------------------------
$mb = [math]::Round((Get-Item $OutputFile).Length / 1MB, 2)
Write-Host ""
Ok "Built: $OutputFile  ($mb MB)"
Info 'Run it by double-clicking (UAC prompts for admin). Simulated UX preview:'
Info "  `"$OutputFile`" -Simulate"
Info 'Keep the exe here inside the repo -- it loads scripts/, tools/, firmware/, apks/ from the repo root.'
