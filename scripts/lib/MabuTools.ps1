# MabuTools.ps1
#
# Shared tool acquisition for every entry point: install-tools.ps1, the CLI
# flashers (flash-mabu.ps1 / flash.ps1) and the GUI core (MabuFlashCore.ps1).
#
# Why this file exists: adb and Zadig are hard requirements for a flash, and each
# entry point used to acquire them on its own -- all of them via winget only. On
# a machine with no winget (Win10 LTSC, older images, anything where App
# Installer was never provisioned) every one of those paths dead-ended, which is
# the single most common fresh-machine failure this project hits. The download
# and verification logic now lives here once, so a fix or a re-pin lands
# everywhere at the same time.
#
# The SHA-256 pins below are the ONLY copy. That is the point: a pin bumped in
# one file and missed in another is a silent, confusing failure, and this repo
# has a long history of exactly that kind of drift between its two editions.
#
# Dot-source it:
#   . (Join-Path $PSScriptRoot 'lib\MabuTools.ps1')          # from scripts\
#   . (Join-Path $PSScriptRoot '..\..\scripts\lib\MabuTools.ps1')   # from app\lib\
#
# Output: callers have different output styles (console Write-Host with colours,
# or the GUI's UI-provider callbacks), so nothing here writes directly. Register
# a logger with Set-MabuToolsLogger; the default prints to the console.

# ---------------------------------------------------------------------------
# Logging indirection
# ---------------------------------------------------------------------------
$script:MabuToolsLog = {
    param([string] $Level, [string] $Message)
    $colour = switch ($Level) {
        'ok'   { 'Green' }
        'warn' { 'DarkYellow' }
        'note' { 'Yellow' }
        default { 'Gray' }
    }
    Write-Host "  [$Level] $Message" -ForegroundColor $colour
}

function Set-MabuToolsLogger {
    # $Logger is invoked as & $Logger <level> <message>, where level is one of
    # ok / note / warn. Lets the GUI route these through its own UI provider.
    param([Parameter(Mandatory)][scriptblock] $Logger)
    $script:MabuToolsLog = $Logger
}

function Write-MabuToolsLog {
    param([string] $Level, [string] $Message)
    & $script:MabuToolsLog $Level $Message
}

# ---------------------------------------------------------------------------
# Pinned artifacts -- the single source of truth
# ---------------------------------------------------------------------------
function Get-MabuToolPin {
    # To re-pin: download the new artifact, verify it however you verify it
    # (Google publishes a SHA-1 in repository2-3.xml; Zadig is Authenticode-signed
    # by "Akeo Consulting"), then update Url and Sha256 together.
    #
    # platform-tools uses Google's VERSIONED archive URL, which is immutable. The
    # rolling "platform-tools-latest-windows.zip" cannot be pinned because its
    # bytes change with every release. r37.0.1 was verified byte-identical to what
    # the rolling URL served at pin time.
    param([Parameter(Mandatory)][ValidateSet('platform-tools', 'zadig')][string] $Name)

    switch ($Name) {
        'platform-tools' {
            return @{
                Url    = 'https://dl.google.com/android/repository/platform-tools_r37.0.1-win.zip'
                Sha256 = '45f4d63113e895ebde0c90f194099a4676b6ac653bd28d54314a9e022bbc1a99'
                Label  = 'platform-tools.zip'
            }
        }
        'zadig' {
            return @{
                Url    = 'https://github.com/pbatard/libwdi/releases/download/v1.5.1/zadig-2.9.exe'
                Sha256 = '4ecaa95df3da3621486a043aef8b3050b8bafe7c901402871e816229ef82039b'
                Label  = 'zadig.exe'
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Hash-pinned download
# ---------------------------------------------------------------------------
function Get-PinnedFile {
    # Download $Url to $Path and refuse anything whose SHA-256 is not $Sha256.
    #
    # HTTPS proves we reached the right host; it does not prove we got the same
    # bytes anyone reviewed. The pin does. It also catches the mundane cases -- a
    # truncated download, a proxy that rewrote the payload, or upstream quietly
    # replacing an artifact at the same URL.
    #
    # The hash doubles as a cache key: a re-run with a good file already on disk
    # skips the download, and a bad file is deleted rather than left behind.
    # Returns $true only on a verified file.
    param(
        [Parameter(Mandatory)][string] $Url,
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $Sha256,
        [Parameter(Mandatory)][string] $Label
    )

    $want = $Sha256.ToLower()
    if (Test-Path $Path) {
        $have = (Get-FileHash -Algorithm SHA256 -Path $Path).Hash.ToLower()
        if ($have -eq $want) {
            Write-MabuToolsLog 'ok' "$Label already present (sha256 verified)"
            return $true
        }
        # Discard it here, not after the re-download. If the download below fails,
        # leaving a known-bad file behind would let the next run -- or a caller
        # that only tests for existence -- pick up bytes that never matched.
        Write-MabuToolsLog 'note' "$Label failed its hash check on disk; discarding and re-downloading"
        Remove-Item $Path -Force
    }

    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    Write-MabuToolsLog 'note' "Downloading $Url ..."
    try {
        # Fresh/unpatched Windows 10 images still negotiate TLS 1.0 by default in
        # .NET, which dl.google.com and github.com both refuse outright.
        [Net.ServicePointManager]::SecurityProtocol =
            [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $Url -OutFile $Path -UseBasicParsing
    } catch {
        Write-MabuToolsLog 'warn' "$Label download failed: $($_.Exception.Message)"
        return $false
    }

    $got = (Get-FileHash -Algorithm SHA256 -Path $Path).Hash.ToLower()
    if ($got -ne $want) {
        Remove-Item $Path -Force
        Write-MabuToolsLog 'warn' "$Label hash mismatch. Expected $want, got $got. Deleted the file."
        Write-MabuToolsLog 'note' 'Either the pin in scripts\lib\MabuTools.ps1 is stale, or the download was tampered with.'
        return $false
    }
    Write-MabuToolsLog 'ok' "$Label downloaded and verified (sha256 $($want.Substring(0,12))...)"
    return $true
}

# ---------------------------------------------------------------------------
# Locators
# ---------------------------------------------------------------------------
# Repo-relative copies are checked FIRST in both locators. That is not a
# preference, it is a correctness requirement: every flasher demands
# Administrator, and if the signed-in user is not a local admin then UAC elevates
# into a DIFFERENT account whose %LOCALAPPDATA% is a different directory
# entirely. A tool installed under the repo is the same file for both accounts.

function Get-MabuAdbPath {
    param([Parameter(Mandatory)][string] $RepoRoot)
    $repo = Join-Path $RepoRoot 'tools\platform-tools\adb.exe'
    if (Test-Path $repo) { return $repo }
    $cmd = Get-Command adb -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $sdk = Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe'
    if (Test-Path $sdk) { return $sdk }
    $wgBase = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'
    if (Test-Path $wgBase) {
        # The winget parent may not exist on a fresh machine, and that wildcard on
        # a missing parent throws under EAP='Stop' -- the original clean-PC crash.
        $hit = Get-ChildItem "$wgBase\Google.PlatformTools_*\platform-tools\adb.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    return $null
}

function Get-MabuZadigPath {
    param([Parameter(Mandatory)][string] $RepoRoot)
    $candidates = @(
        (Join-Path $RepoRoot 'tools\zadig.exe'),
        (Join-Path $RepoRoot 'tools\zadig\zadig*.exe'),
        "$env:USERPROFILE\scoop\apps\zadig\current\zadig.exe",
        "$env:USERPROFILE\scoop\shims\zadig.exe",
        "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\akeo.ie.Zadig*\zadig*.exe",
        "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Akeo.Zadig*\zadig*.exe",
        "$env:ProgramFiles\Zadig\zadig.exe",
        "${env:ProgramFiles(x86)}\Zadig\zadig.exe"
    )
    foreach ($pat in $candidates) {
        $hit = Get-ChildItem -Path $pat -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    $cmd = Get-Command zadig -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Test-MabuWinget {
    # winget is absent on Win10 LTSC / Server and on machines where App Installer
    # was never provisioned. Calling it blind is a terminating
    # CommandNotFoundException, so every auto-install path checks this first.
    return [bool](Get-Command winget -ErrorAction SilentlyContinue)
}

# ---------------------------------------------------------------------------
# Acquisition
# ---------------------------------------------------------------------------
function Install-MabuAdb {
    # Ensure adb is available and return its path, or $null. Prefers whatever is
    # already installed, then winget when present, then the pinned direct
    # download -- which is the path that matters, because winget is exactly what
    # is missing on the machines that need help.
    param([Parameter(Mandatory)][string] $RepoRoot)

    $adb = Get-MabuAdbPath -RepoRoot $RepoRoot
    if ($adb) { return $adb }

    if (Test-MabuWinget) {
        Write-MabuToolsLog 'note' 'Installing Google platform-tools via winget...'
        Start-Process winget `
            -ArgumentList 'install','--id','Google.PlatformTools','-e','--accept-source-agreements','--accept-package-agreements' `
            -NoNewWindow -Wait | Out-Null
        $adb = Get-MabuAdbPath -RepoRoot $RepoRoot
        if ($adb) { return $adb }
        Write-MabuToolsLog 'warn' 'winget finished but adb was not found; falling back to a direct download.'
    }

    $pin   = Get-MabuToolPin -Name 'platform-tools'
    $tools = Join-Path $RepoRoot 'tools'
    $zip   = Join-Path $tools 'platform-tools.zip'
    if (-not (Get-PinnedFile -Url $pin.Url -Path $zip -Sha256 $pin.Sha256 -Label $pin.Label)) { return $null }

    try {
        if (-not (Test-Path $tools)) { New-Item -ItemType Directory -Path $tools -Force | Out-Null }
        # The zip carries a top-level platform-tools\ folder, so this lands at
        # <repo>\tools\platform-tools\adb.exe.
        Expand-Archive -Path $zip -DestinationPath $tools -Force
    } catch {
        Write-MabuToolsLog 'warn' "Unpacking platform-tools failed: $($_.Exception.Message)"
        return $null
    }

    $adb = Get-MabuAdbPath -RepoRoot $RepoRoot
    if (-not $adb) { Write-MabuToolsLog 'warn' "Unpacked platform-tools but no adb.exe under $tools." }
    return $adb
}

function Install-MabuZadig {
    # Ensure Zadig is available and return its path, or $null. Zadig ships as a
    # single unpacked .exe, so dropping the file in tools\ IS the install.
    param([Parameter(Mandatory)][string] $RepoRoot)

    $pin   = Get-MabuToolPin -Name 'zadig'
    $local = Join-Path $RepoRoot 'tools\zadig.exe'

    # Re-verify our own managed copy before handing it out. The pin protects the
    # download; it does nothing for a file already sitting at the target path,
    # and Get-MabuZadigPath resolves that path by existence alone. Package-manager
    # locations are left alone -- not ours to police, and they carry their own
    # signatures.
    if ((Test-Path $local) -and
        ((Get-FileHash -Algorithm SHA256 -Path $local).Hash.ToLower() -ne $pin.Sha256)) {
        Write-MabuToolsLog 'warn' "$local failed its hash check; discarding it."
        Remove-Item $local -Force
    }

    $zadig = Get-MabuZadigPath -RepoRoot $RepoRoot
    if ($zadig) { return $zadig }

    if (Test-MabuWinget) {
        Write-MabuToolsLog 'note' 'Installing Zadig via winget...'
        Start-Process winget `
            -ArgumentList 'install','--id','akeo.ie.Zadig','-e','--accept-source-agreements','--accept-package-agreements' `
            -NoNewWindow -Wait | Out-Null
        $zadig = Get-MabuZadigPath -RepoRoot $RepoRoot
        if ($zadig) { return $zadig }
        Write-MabuToolsLog 'warn' 'winget finished but Zadig was not found; falling back to a direct download.'
    }

    if (Get-PinnedFile -Url $pin.Url -Path $local -Sha256 $pin.Sha256 -Label $pin.Label) {
        return (Get-MabuZadigPath -RepoRoot $RepoRoot)
    }
    return $null
}
