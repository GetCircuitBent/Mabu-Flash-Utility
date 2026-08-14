# build-bootstrap.ps1
#
# Compile app\bootstrap\MabuFlashSetup.cs into MabuFlashSetup.exe -- the single
# file users download.
#
# Uses the csc.exe that ships with the .NET Framework in Windows. No SDK, no
# NuGet, no PSGallery module: the same "no heavy toolchain" approach the APK
# build takes with raw aapt/d8/apksigner instead of Gradle. It also keeps the
# output clear of the heuristic-detection category ps2exe binaries fall into.
#
# The exe targets .NET Framework 4.x, which is present on every Windows 10/11
# install, so there is no runtime for the user to fetch.
#
# Usage:
#   .\app\bootstrap\build-bootstrap.ps1
#   .\app\bootstrap\build-bootstrap.ps1 -OutputFile D:\releases\MabuFlashSetup.exe
#   .\app\bootstrap\build-bootstrap.ps1 -CertThumbprint <hex>    # Authenticode-sign
#   .\app\bootstrap\build-bootstrap.ps1 -EmbedPayload dist\mabuflash-payload-0.1.0.zip
#
# -EmbedPayload builds the STANDALONE variant: the payload zip is compiled into
# the exe as a resource, so it needs no network, no GitHub release, and nothing
# beside it on disk. The exe grows by the size of the zip (~89 MB). Use it for
# testing and for anyone who cannot reach GitHub; the normal downloading build
# stays the release artifact.
#
# Signing: -CertThumbprint reads a cert from Cert:\CurrentUser\My, which works
# with a hardware token plugged in (the cert surfaces in the store, the key stays
# on the token). It does NOT work with cloud signing services such as Azure
# Artifact Signing -- those need signtool with their dlib, which is a separate
# step to add when a signing route is chosen.

[CmdletBinding()]
param(
    [string] $OutputFile,
    [string] $IconFile,
    [string] $Version = '1.0.0.0',
    [string] $CertThumbprint,
    [string] $EmbedPayload
)

$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$Source   = Join-Path $PSScriptRoot 'MabuFlashSetup.cs'
$Manifest = Join-Path $PSScriptRoot 'MabuFlashSetup.manifest'

# Standalone: resolve the payload and derive the resource name the exe looks for.
# The tag embeds a short hash of the zip, so every rebuild extracts to its own
# folder under %LOCALAPPDATA%\MabuFlash instead of reusing a stale install that
# still carries a .complete marker.
$ResourceArg = $null
if ($EmbedPayload) {
    if (-not (Test-Path $EmbedPayload)) { throw "Payload zip not found: $EmbedPayload" }
    $payload = (Resolve-Path $EmbedPayload).Path
    $payVer  = if ((Split-Path $payload -Leaf) -match 'mabuflash-payload-(.+)\.zip$') { $Matches[1] } else { 'local' }
    $sha8    = (Get-FileHash -Algorithm SHA256 -Path $payload).Hash.Substring(0,8).ToLower()
    $ResourceArg = "/resource:$payload,MabuFlashPayload-$payVer-$sha8.zip"
}

if (-not $OutputFile) {
    $OutputFile = if ($EmbedPayload) { Join-Path $RepoRoot 'dist\MabuFlashStandalone.exe' }
                  else               { Join-Path $RepoRoot 'dist\MabuFlashSetup.exe' }
}

function Info($m) { Write-Host "  $m" -ForegroundColor Gray }
function Ok($m)   { Write-Host "  $m" -ForegroundColor Green }
function Warn($m) { Write-Host "  $m" -ForegroundColor Yellow }

Write-Host "`n==== Build MabuFlashSetup.exe ====" -ForegroundColor Cyan

foreach ($f in @($Source, $Manifest)) {
    if (-not (Test-Path $f)) { throw "Missing build input: $f" }
}

# ---------------------------------------------------------------------------
# 1. Locate csc.exe
# ---------------------------------------------------------------------------
# Newest framework version wins. v4.0.30319 is the one present on Win10/11.
$csc = Get-ChildItem 'C:\Windows\Microsoft.NET\Framework64' -Directory -ErrorAction SilentlyContinue |
       Sort-Object Name -Descending |
       ForEach-Object { Join-Path $_.FullName 'csc.exe' } |
       Where-Object { Test-Path $_ } |
       Select-Object -First 1
if (-not $csc) {
    throw "csc.exe not found under C:\Windows\Microsoft.NET\Framework64. The .NET Framework is missing, which should not happen on Windows 10 or later."
}
Ok "csc: $csc"

# ---------------------------------------------------------------------------
# 2. Version metadata
# ---------------------------------------------------------------------------
# csc has no /version switch, so the attributes go in a generated source file
# compiled alongside the main one.
$asmInfo = Join-Path ([IO.Path]::GetTempPath()) ("MabuFlashSetupInfo-" + [guid]::NewGuid().ToString('N').Substring(0,8) + ".cs")
@"
using System.Reflection;
[assembly: AssemblyTitle("Mabu Flash Setup")]
[assembly: AssemblyProduct("Mabu Flash Utility")]
[assembly: AssemblyCompany("Get Circuit Bent")]
[assembly: AssemblyDescription("Downloads and launches the Mabu Flash Utility")]
[assembly: AssemblyVersion("$Version")]
[assembly: AssemblyFileVersion("$Version")]
"@ | Set-Content -Path $asmInfo -Encoding UTF8

# ---------------------------------------------------------------------------
# 3. Compile
# ---------------------------------------------------------------------------
$outDir = Split-Path -Parent $OutputFile
if ($outDir -and -not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }

# A running MabuFlashSetup.exe locks the file; a stale success is worse than a
# clear failure.
if (Test-Path $OutputFile) {
    Remove-Item $OutputFile -Force -ErrorAction SilentlyContinue
    if (Test-Path $OutputFile) {
        throw "Cannot overwrite $OutputFile -- it is locked. Close it, then re-run."
    }
}

if (-not $IconFile) {
    $ico = Get-ChildItem (Join-Path $RepoRoot 'app'), (Join-Path $RepoRoot 'assets') `
           -Filter *.ico -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($ico) { $IconFile = $ico.FullName }
}

$args = @(
    '/nologo'
    '/target:winexe'            # no console window
    '/platform:anycpu'
    '/optimize+'
    "/out:$OutputFile"
    "/win32manifest:$Manifest"
    '/reference:System.dll'
    '/reference:System.Core.dll'
    '/reference:System.Drawing.dll'
    '/reference:System.Windows.Forms.dll'
    '/reference:System.IO.Compression.dll'
    '/reference:System.IO.Compression.FileSystem.dll'
)
if ($IconFile) { $args += "/win32icon:$IconFile"; Info "icon: $IconFile" }
if ($ResourceArg) {
    $args += $ResourceArg
    $pmb = [math]::Round((Get-Item $payload).Length / 1MB, 1)
    Info "embedding payload: $(Split-Path $payload -Leaf)  ($pmb MB)"
}
$args += $Source
$args += $asmInfo

Info "compiling -> $OutputFile"
& $csc @args
if ($LASTEXITCODE -ne 0) { throw "csc failed with exit code $LASTEXITCODE." }
Remove-Item $asmInfo -Force -ErrorAction SilentlyContinue
if (-not (Test-Path $OutputFile)) { throw 'csc reported success but produced no exe.' }

# ---------------------------------------------------------------------------
# 4. Optional Authenticode signing
# ---------------------------------------------------------------------------
if ($CertThumbprint) {
    $cert = Get-Item "Cert:\CurrentUser\My\$CertThumbprint" -ErrorAction Stop
    $sig  = Set-AuthenticodeSignature -FilePath $OutputFile -Certificate $cert `
            -TimestampServer 'http://timestamp.digicert.com'
    if ($sig.Status -ne 'Valid') { Warn "Signing status: $($sig.Status) - $($sig.StatusMessage)" }
    else { Ok "Signed with $($cert.Subject)" }
} else {
    Warn 'Unsigned. SmartScreen will warn users until this is signed.'
    Info 'Re-run with -CertThumbprint <hex> once a signing certificate is in place.'
}

$kb = [math]::Round((Get-Item $OutputFile).Length / 1KB, 1)
Write-Host ''
Ok "built: $OutputFile  ($kb KB)"
Info 'Attach this to the GitHub release alongside mabuflash-payload-<version>.zip'
Info 'and its .sha256 sidecar. The exe finds the payload via the Releases API.'
