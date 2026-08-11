# dump-system-cycled.ps1
#
# Auto-cycled bulk Loader dump. Discovery: a fresh Loader session reliably
# yields ~6-7 4MB reads (~24-28 MB) before wedging. Once wedged, rd does NOT
# work -- the device needs a physical power cycle. So we stay conservative:
# do N chunks per session, rd cleanly *before* wedge, re-enter via wifi adb
# `reboot loader`, resume.
#
# State file (firmware/scratch/<Name>.state.json) tracks the next byte offset, so the
# script can be interrupted and resumed. Output goes to firmware/scratch/<Name>.img,
# opened in append mode.
#
# Pre-reqs:
#   - WiFi ADB live to $WifiAdb (default 10.0.0.147:5555)
#   - Device currently in Loader OR booted to Android (script handles both)
#   - rkdeveloptool at tools/rkdeveloptool/rkdeveloptool.exe
#
# Usage:
#   .\scripts\dump-system-cycled.ps1                  # dump full /system
#   .\scripts\dump-system-cycled.ps1 -ChunksPerSession 4
#   .\scripts\dump-system-cycled.ps1 -TotalMB 256     # cap dump length
#
# To resume after manual power cycle: just re-run; reads state file.

[CmdletBinding()]
param(
    [string] $Name = 'system-full',
    [int]    $PartitionStartLBA = 0x18A000,
    [int]    $TotalMB = 2048,            # /system is exactly 2 GB
    [int]    $ChunkSectors = 8192,       # 4 MB per read
    [int]    $ChunksPerSession = 5,      # safety: 5 * 4MB = 20 MB, well under wedge
    [int]    $ChunkTimeoutSec = 25,
    [string] $WifiAdb = '192.168.0.18:5555',
    [switch] $StartFresh                  # zero out state file & output
)

$ErrorActionPreference = 'Stop'
$Root    = Split-Path -Parent $PSScriptRoot
$RK      = Join-Path $Root 'tools\rkdeveloptool\rkdeveloptool.exe'
# Same candidate order as Find-Adb in the flashers -- keep them in step. This
# used to check only the winget package dir, with no -ErrorAction: under
# $ErrorActionPreference='Stop' the wildcard on a missing parent threw a raw
# terminating error, so the friendly message below never printed, and adb
# installed by install-tools.ps1 was never found at all on a winget-less PC.
function Find-Adb {
    $repo = Join-Path $Root 'tools\platform-tools\adb.exe'
    if (Test-Path $repo) { return $repo }
    $cmd = Get-Command adb -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $sdk = Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe'
    if (Test-Path $sdk) { return $sdk }
    $wgBase = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'
    if (Test-Path $wgBase) {
        $hit = Get-ChildItem "$wgBase\Google.PlatformTools_*\platform-tools\adb.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    return $null
}
$ADB = Find-Adb
if (-not $ADB) { throw "adb.exe not found. Run .\scripts\install-tools.ps1 first." }

$DumpDir = Join-Path $Root 'firmware\scratch'
$OutFile = Join-Path $DumpDir "$Name.img"
$StateFile = Join-Path $DumpDir "$Name.state.json"

if ($StartFresh) {
    Remove-Item $OutFile,$StateFile -ErrorAction SilentlyContinue
}

$TotalBytes = [int64]$TotalMB * 1MB
$ChunkBytes = $ChunkSectors * 512

# Load resume state
$startOffset = 0
if (Test-Path $StateFile) {
    $state = Get-Content $StateFile -Raw | ConvertFrom-Json
    $startOffset = [int64]$state.NextOffset
    Write-Host "Resuming at offset $startOffset ($([math]::Round($startOffset/1MB,1)) MB)" -ForegroundColor Yellow
}
if ((Test-Path $OutFile) -and ((Get-Item $OutFile).Length -ne $startOffset)) {
    # File length and state disagree -- trust file length
    $startOffset = (Get-Item $OutFile).Length
    Write-Host "State mismatch -- using file length $startOffset" -ForegroundColor Yellow
}

function Save-State($offset) {
    @{ NextOffset = $offset; UpdatedUtc = (Get-Date).ToUniversalTime().ToString('o') } | ConvertTo-Json | Set-Content $StateFile
}

function Test-Loader {
    $r = & $RK ld 2>&1
    return ($r -match 'Vid=0x2207,Pid=0x320a.*Loader')
}

function Enter-Loader {
    # If already in Loader, fine.
    if (Test-Loader) { return $true }
    # Otherwise expect Android up on wifi adb. Send reboot loader.
    Write-Host "Asking Android to reboot into Loader..." -ForegroundColor Cyan
    $null = & $ADB connect $WifiAdb 2>&1
    $alive = $false
    for ($i = 0; $i -lt 30; $i++) {
        $r = & $ADB -s $WifiAdb shell echo ok 2>&1
        if ($r -match '^ok') { $alive = $true; break }
        Start-Sleep -Seconds 2
        $null = & $ADB connect $WifiAdb 2>&1
    }
    if (-not $alive) { return $false }
    & $ADB -s $WifiAdb shell reboot loader 2>&1 | Out-Null
    # Poll for Loader
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Seconds 1
        if (Test-Loader) { return $true }
    }
    return $false
}

function Exit-Loader {
    & $RK rd 2>&1 | Out-Null
    Start-Sleep -Seconds 2
}

# Open append stream
$stream = [System.IO.File]::Open($OutFile, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write)
$tmpChunk = "$env:TEMP\rk-dump-cycled.bin"

$cycle = 0
$swTotal = [Diagnostics.Stopwatch]::StartNew()
try {
    $offset = $startOffset
    while ($offset -lt $TotalBytes) {
        $cycle++
        if (-not (Enter-Loader)) {
            Write-Host "Could not enter Loader. Power-cycle the tablet and re-run." -ForegroundColor Red
            break
        }
        Write-Host ("Cycle {0}: starting at {1:N0} B ({2:N1} MB / {3} MB)" -f $cycle, $offset, ($offset/1MB), $TotalMB) -ForegroundColor Cyan

        $cycleBytes = 0
        $wedged = $false
        for ($k = 0; $k -lt $ChunksPerSession; $k++) {
            if ($offset -ge $TotalBytes) { break }
            $remaining = $TotalBytes - $offset
            $thisChunkSectors = [int]([Math]::Min($ChunkSectors, [Math]::Floor($remaining / 512)))
            $thisChunkBytes = $thisChunkSectors * 512
            $absLBA = $PartitionStartLBA + [int64]($offset / 512)
            if (Test-Path $tmpChunk) { Remove-Item $tmpChunk -Force }
            $sw = [Diagnostics.Stopwatch]::StartNew()
            $p = Start-Process -FilePath $RK -ArgumentList @('rl', $absLBA, $thisChunkSectors, $tmpChunk) -NoNewWindow -PassThru -RedirectStandardOutput "$tmpChunk.out" -RedirectStandardError "$tmpChunk.err"
            $finished = $p.WaitForExit($ChunkTimeoutSec * 1000)
            $sw.Stop()
            if (-not $finished) {
                Write-Host ("  WEDGE TIMEOUT at offset {0:N0} after {1}s" -f $offset, $ChunkTimeoutSec) -ForegroundColor Red
                try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch {}
                Get-Process rkdeveloptool -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
                $wedged = $true; break
            }
            $sz = if (Test-Path $tmpChunk) { (Get-Item $tmpChunk).Length } else { 0 }
            if ($p.ExitCode -ne 0 -or $sz -ne $thisChunkBytes) {
                Write-Host ("  WEDGE PARTIAL at offset {0:N0} (got {1}/{2} B, rc={3})" -f $offset, $sz, $thisChunkBytes, $p.ExitCode) -ForegroundColor Red
                # Append what we got (only full chunks count); discard partial
                $wedged = $true; break
            }
            $bytes = [System.IO.File]::ReadAllBytes($tmpChunk)
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush()
            $offset += $thisChunkBytes
            $cycleBytes += $thisChunkBytes
            Write-Host ("  chunk {0}  abs=0x{1:X}  dt={2,5:N2}s  total {3,6:N1} MB" -f ($k+1), $absLBA, $sw.Elapsed.TotalSeconds, ($offset/1MB)) -ForegroundColor DarkGray
        }
        Remove-Item $tmpChunk,"$tmpChunk.out","$tmpChunk.err" -ErrorAction SilentlyContinue
        Save-State $offset

        if ($wedged) {
            Write-Host "Wedge encountered. The device usually needs a physical power cycle now." -ForegroundColor Yellow
            Write-Host "Resume by re-running this script after power-cycling the tablet back to Android (so wifi adb is up) or back to Loader directly." -ForegroundColor Yellow
            break
        }

        if ($offset -lt $TotalBytes) {
            Exit-Loader
        }
    }
    $swTotal.Stop()
    Write-Host ""
    Write-Host ("DONE.  read total {0:N0} B ({1:N1} MB)  elapsed {2:N1}s  cycles={3}" -f (Get-Item $OutFile).Length, ((Get-Item $OutFile).Length/1MB), $swTotal.Elapsed.TotalSeconds, $cycle) -ForegroundColor Green
} finally {
    $stream.Close()
    Remove-Item $tmpChunk,"$tmpChunk.out","$tmpChunk.err" -ErrorAction SilentlyContinue
}
