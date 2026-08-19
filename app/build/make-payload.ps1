# make-payload.ps1
#
# Build the release payload zip that MabuFlashSetup.exe downloads and extracts.
#
# The payload is the RUNTIME subset of the repo -- everything the GUI touches
# while flashing, and nothing else. Archival material stays out: firmware\originals
# (33 MB of captured originals, only needed to restore a unit), tools\rockchip-stock
# (16.5 MB of reference Rockchip drivers the flash never invokes) and guides\.
#
# Deliberately NOT bundled, even though the GUI needs them:
#   adb (Google platform-tools) and zadig.exe. Both are acquired at first run by
#   scripts\lib\MabuTools.ps1, hash-pinned. Google's platform-tools ships under
#   the Android SDK Terms, which restrict redistribution, so shipping a copy
#   inside our zip is a licensing question we do not need to answer -- and the
#   pinned download already works on machines with no winget.
#
# Layout note: the zip contains the repo tree at its root (app\, scripts\, ...),
# so extracting it to <dir> makes <dir> a valid repo root. MabuFlashGui.ps1
# locates itself by finding app\lib\MabuFlashCore.ps1 and takes the parent as the
# repo root, so nothing has to be told where it landed.
#
# Usage:
#   .\app\build\make-payload.ps1 -Version 1.0.0
#   .\app\build\make-payload.ps1 -Version 1.0.0 -OutDir D:\releases

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $Version,
    [string] $OutDir
)

$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
if (-not $OutDir) { $OutDir = Join-Path $RepoRoot 'dist' }

function Info($m) { Write-Host "  $m" -ForegroundColor Gray }
function Ok($m)   { Write-Host "  $m" -ForegroundColor Green }
function Warn($m) { Write-Host "  $m" -ForegroundColor Yellow }

Write-Host "`n==== Build MabuFlash payload $Version ====" -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# 1. What goes in
# ---------------------------------------------------------------------------
# Directories copied wholesale, and single files. Anything not listed is out --
# an allow-list, not a deny-list, so a new archival folder cannot silently
# balloon the download.
$IncludeDirs = @(
    'app\lib',
    'scripts',
    'assets',
    'firmware\patches',
    'tools\rkdeveloptool',
    'tools\magiskpolicy',
    'apks',
    'mabu-archive'
)
$IncludeFiles = @(
    'app\MabuFlashGui.ps1',
    'FLASH-A-NEW-MABU.md',
    'README.md',
    # The canonical procedure. It ships because the installed copy is what an
    # operator has in front of them offline, and because every other doc here
    # is required to agree with it -- shipping those without it leaves the
    # tiebreaker on GitHub only.
    'PROCEDURE.md'
)

# Excluded even inside an included directory. These are the runtime-acquired
# tools and local scratch: they are gitignored, but a dev machine will have them
# sitting in the tree and they must not ride along.
$ExcludePatterns = @(
    '\\tools\\platform-tools\\',
    '\\tools\\platform-tools\.zip$',
    '\\tools\\zadig\.exe$',
    '\\tools\\google-usb-driver',
    '\\firmware\\scratch\\'
)

# Must exist in the finished payload or the GUI cannot flash.
$Required = @(
    'app\MabuFlashGui.ps1',
    'app\lib\MabuFlashCore.ps1',
    'app\lib\MabuUi.ps1',
    'scripts\lib\MabuTools.ps1',
    'scripts\install-tools.ps1',
    'scripts\install-android-driver.ps1',
    'scripts\liberate-mabu.ps1',
    'scripts\wipe-data-head.ps1',
    'scripts\dump-system-cycled.ps1',
    'tools\rkdeveloptool\rkdeveloptool.exe',
    'tools\magiskpolicy\magiskpolicy-armeabi-v7a',
    'firmware\patches\parameter-patched.img',
    'apks\F-Droid.apk',
    'apks\Lawnchair.apk'
)

# ---------------------------------------------------------------------------
# 2. Stage
# ---------------------------------------------------------------------------
$stage = Join-Path ([IO.Path]::GetTempPath()) ("mabuflash-payload-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $stage -Force | Out-Null

function Test-Excluded([string] $FullPath) {
    foreach ($pat in $ExcludePatterns) { if ($FullPath -match $pat) { return $true } }
    return $false
}

$copied = 0
foreach ($d in $IncludeDirs) {
    $src = Join-Path $RepoRoot $d
    if (-not (Test-Path $src)) { Warn "skipping missing directory: $d"; continue }
    foreach ($f in Get-ChildItem $src -Recurse -File) {
        if (Test-Excluded $f.FullName) { continue }
        $rel  = $f.FullName.Substring($RepoRoot.Length).TrimStart('\')
        $dest = Join-Path $stage $rel
        $dir  = Split-Path -Parent $dest
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Copy-Item $f.FullName $dest
        $copied++
    }
}
foreach ($f in $IncludeFiles) {
    $src = Join-Path $RepoRoot $f
    if (-not (Test-Path $src)) { Warn "skipping missing file: $f"; continue }
    $dest = Join-Path $stage $f
    $dir  = Split-Path -Parent $dest
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Copy-Item $src $dest
    $copied++
}
Ok "staged $copied files"

# ---------------------------------------------------------------------------
# 3. Verify the payload can actually flash
# ---------------------------------------------------------------------------
$missing = $Required | Where-Object { -not (Test-Path (Join-Path $stage $_)) }
if ($missing) {
    Write-Host ''
    Warn 'Payload is missing files the GUI needs at runtime:'
    $missing | ForEach-Object { Warn "  - $_" }
    throw 'Refusing to build an unusable payload.'
}
Ok 'runtime payload verified (all required files present)'

# Belt and braces: nothing that should have been excluded slipped through.
$leaked = Get-ChildItem $stage -Recurse -File | Where-Object { Test-Excluded $_.FullName }
if ($leaked) {
    $leaked | ForEach-Object { Warn "leaked: $($_.FullName.Substring($stage.Length))" }
    throw 'Excluded files ended up in the payload.'
}

# ---------------------------------------------------------------------------
# 4. Zip + hash
# ---------------------------------------------------------------------------
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
$zipName = "mabuflash-payload-$Version.zip"
$zipPath = Join-Path $OutDir $zipName
if (Test-Path $zipPath) { Remove-Item $zipPath -Force }

Info "compressing -> $zipPath"
# Optimal, not SmallestSize: the bulk is APKs and other already-compressed zip
# containers, so extra effort buys almost nothing and costs minutes.
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zipPath -CompressionLevel Optimal

$sha = (Get-FileHash -Algorithm SHA256 -Path $zipPath).Hash.ToLower()
# Sidecar for the bootstrapper to verify against, in the standard
# "<hash>  <filename>" shape so sha256sum can read it too.
"$sha  $zipName" | Set-Content -Path "$zipPath.sha256" -Encoding ASCII -NoNewline

Remove-Item $stage -Recurse -Force

$mb = [math]::Round((Get-Item $zipPath).Length / 1MB, 1)
Write-Host ''
Ok "payload: $zipPath  ($mb MB)"
Ok "sha256 : $sha"
Info "sidecar: $zipPath.sha256"
Write-Host ''
Info 'Attach BOTH files to the GitHub release. MabuFlashSetup.exe reads the'
Info 'sidecar to verify the zip before extracting it.'
