<#
.SYNOPSIS
    Build the signed, publishable Mabu Signboard APK and verify it.

.DESCRIPTION
    Produces the file that gets attached to a GitHub release, named the way the
    install guide says it will be named, and checks it before you publish it.

    This is deliberately NOT scripts/install.ps1. That one builds a debug APK
    and pushes it to a tablet you are iterating on. This one builds the artifact
    other people download, so it checks the things that only hurt other people:

      * Signed with the shared release key, not the per-machine debug key. A
        debug-signed release strands every user on
        INSTALL_FAILED_UPDATE_INCOMPATIBLE the first time they try to update.
      * armeabi-v7a only, minSdk <= 27, and not debuggable.
      * Named mabu-signboard.apk, not app-release.apk.

    Output lands in <repo>\dist\, which is gitignored.

    Signing credentials are never passed on the command line. The build finds
    them itself: keystore.properties in the sample root, MABU_KEYSTORE and
    friends in the environment, or ~/.mabu-keys/keystore.properties. See
    "Shipping a Sample App" in sample-apps/SAMPLE-APP-FUNCTION-INDEX.md.

.PARAMETER OutDir
    Where to put the finished APK. Defaults to <repo>\dist.

.PARAMETER SkipBuild
    Verify and stage the APK Gradle already produced, without rebuilding.

.EXAMPLE
    ./scripts/build-release.ps1
#>
[CmdletBinding()]
param(
    [string] $OutDir,
    [switch] $SkipBuild
)

$ErrorActionPreference = 'Stop'

$AppName  = 'mabu-signboard'
$Pkg      = 'com.getcircuitbent.mabu.signboard'
$ProjDir  = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$RepoRoot = (Resolve-Path (Join-Path $ProjDir '..\..')).Path
$BuiltApk = Join-Path $ProjDir 'app\build\outputs\apk\release\app-release.apk'

if (-not $OutDir) { $OutDir = Join-Path $RepoRoot 'dist' }

function Info($m) { Write-Host "[*] $m"  -ForegroundColor Cyan }
function Ok($m)   { Write-Host "[OK] $m" -ForegroundColor Green }
function Fail($m) { throw $m }

# --- Locate the SDK build-tools -------------------------------------------
# aapt2 and apksigner live there. Prefer the version the app compiles against
# (34), but any newer one reads an older APK fine, so take the highest.
$sdkDir = $null
$localProps = Join-Path $ProjDir 'local.properties'
if (Test-Path $localProps) {
    $sdkDir = (Get-Content $localProps | Where-Object { $_ -match '^\s*sdk\.dir\s*=' }) -replace '^\s*sdk\.dir\s*=\s*', ''
    $sdkDir = $sdkDir -replace '\\\\', '\'
}
if (-not $sdkDir) { $sdkDir = $env:ANDROID_HOME }
if (-not $sdkDir) { $sdkDir = $env:ANDROID_SDK_ROOT }
if (-not $sdkDir) { $sdkDir = Join-Path $env:LOCALAPPDATA 'Android\Sdk' }
if (-not (Test-Path $sdkDir)) {
    Fail "Android SDK not found. Set sdk.dir in $localProps, or ANDROID_HOME."
}

$buildTools = Get-ChildItem (Join-Path $sdkDir 'build-tools') -Directory |
              Sort-Object { [version]($_.Name -replace '[^0-9.].*$', '') } |
              Select-Object -Last 1
if (-not $buildTools) { Fail "No build-tools under $sdkDir. Install them via Android Studio's SDK Manager." }

$aapt2     = Join-Path $buildTools.FullName 'aapt2.exe'
$apksigner = Join-Path $buildTools.FullName 'apksigner.bat'
Info "Using build-tools $($buildTools.Name)"

# --- 1. Build --------------------------------------------------------------
if (-not $SkipBuild) {
    Info 'Building signed release APK'
    Push-Location $ProjDir
    try {
        & .\gradlew.bat assembleRelease
        # The build itself fails with an explanation if no keystore is
        # configured, rather than quietly emitting an unsigned APK.
        if ($LASTEXITCODE -ne 0) { Fail 'Gradle build failed.' }
    } finally {
        Pop-Location
    }
}

if (-not (Test-Path $BuiltApk)) {
    $unsigned = Join-Path $ProjDir 'app\build\outputs\apk\release\app-release-unsigned.apk'
    if (Test-Path $unsigned) {
        Fail "Only an UNSIGNED apk was produced. No release keystore was found; see 'Shipping a Sample App' in the Sample App Function Index."
    }
    Fail "No APK at $BuiltApk. Build first (drop -SkipBuild)."
}

# --- 2. Verify the signature ----------------------------------------------
# minSdk is passed explicitly so apksigner judges the APK by the platform it
# actually targets. v1 (JAR) signing is intentionally absent: AGP drops it once
# minSdk is 24+, and the Mabu (API 27) verifies v2.
Info 'Verifying signature'
$signerOut = & $apksigner verify --min-sdk-version 24 --print-certs $BuiltApk 2>&1
if ($LASTEXITCODE -ne 0) { Write-Host $signerOut; Fail 'Signature verification failed.' }

$certLine = $signerOut | Select-String 'certificate DN:' | Select-Object -First 1
$sha256Line = $signerOut | Select-String 'certificate SHA-256 digest:' | Select-Object -First 1
if (-not $certLine) { Fail 'APK is not signed.' }
if ($certLine -match 'CN=Android Debug|CN=Android') {
    Fail 'APK is signed with the DEBUG key. Do not publish this. Check your keystore configuration.'
}
Ok "Signed by: $($certLine.ToString().Trim())"
Write-Host "    $($sha256Line.ToString().Trim())" -ForegroundColor Gray

# --- 3. Verify the APK is right for the hardware --------------------------
Info 'Checking the APK against what a Mabu will accept'
$badging = & $aapt2 dump badging $BuiltApk

function Field($pattern) {
    $m = $badging | Select-String $pattern | Select-Object -First 1
    if ($m) { $m.ToString().Trim() } else { $null }
}

$pkgLine    = Field "^package:"
# build-tools 34 prints "sdkVersion:'24'"; build-tools 37 renamed it to
# "minSdkVersion:'24'". Accept either, and insist on finding one: a check that
# silently compares against an empty string is worse than no check at all.
$minSdk     = (Field "^(min)?[sS]dkVersion:") -replace "^(min)?[sS]dkVersion:'|'$", ''
$targetSdk  = (Field "^targetSdkVersion:")    -replace "targetSdkVersion:'|'", ''
$nativeCode = (Field "^native-code:")
$launchable = Field "^launchable-activity:"
$debuggable = Field "application-debuggable"

if ($pkgLine -notmatch [regex]::Escape("name='$Pkg'")) { Fail "Wrong package. Expected $Pkg. Got: $pkgLine" }
if (-not ($minSdk -match '^\d+$'))    { Fail "Could not read minSdk from aapt2 badging output." }
if (-not ($targetSdk -match '^\d+$')) { Fail "Could not read targetSdk from aapt2 badging output." }
if ([int]$minSdk -gt 27)    { Fail "minSdk $minSdk is above the Mabu's API 27. It will not install." }
if ([int]$targetSdk -gt 28) { Fail "targetSdk $targetSdk. This sample pins 28 on purpose; see app/build.gradle.kts." }
if ($nativeCode -notmatch 'armeabi-v7a') { Fail "No armeabi-v7a native code: $nativeCode" }
if ($nativeCode -match 'arm64|x86')      { Fail "APK carries an ABI the RK3288 cannot use: $nativeCode" }
if ($debuggable) { Fail 'APK is marked debuggable. That is a debug build.' }
if (-not $launchable) { Fail 'No launchable activity. `am start` in the install guide would fail.' }

$versionCode = ([regex]"versionCode='(\d+)'").Match($pkgLine).Groups[1].Value
$versionName = ([regex]"versionName='([^']*)'").Match($pkgLine).Groups[1].Value

Ok "package $Pkg, versionCode $versionCode, versionName $versionName"
Ok "minSdk $minSdk, targetSdk $targetSdk, $nativeCode, not debuggable"

# The install guide tells users to pre-grant exactly these. If the app starts
# declaring another dangerous permission, that page has to be updated or the
# first thing a user sees is a permission dialog on a robot they are driving
# from a PC.
$declared = ($badging | Select-String "^uses-permission: name='android.permission" |
             ForEach-Object { ([regex]"name='([^']*)'").Match($_).Groups[1].Value })
$dangerous = $declared | Where-Object {
    $_ -match 'READ_EXTERNAL_STORAGE|WRITE_EXTERNAL_STORAGE|CAMERA|RECORD_AUDIO|ACCESS_FINE_LOCATION'
}
Info "Runtime permissions the install guide must pre-grant:"
$dangerous | ForEach-Object { Write-Host "      $_" -ForegroundColor Gray }

# --- 4. Stage it under its published name ---------------------------------
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir | Out-Null }
$final = Join-Path $OutDir "$AppName.apk"
Copy-Item $BuiltApk $final -Force

$hash = (Get-FileHash $final -Algorithm SHA256).Hash.ToLower()
$sizeMb = [math]::Round((Get-Item $final).Length / 1MB, 2)
"$hash  $AppName.apk" | Set-Content -Path "$final.sha256" -Encoding utf8

Ok "$final  ($sizeMb MB)"
Write-Host "    SHA-256: $hash" -ForegroundColor Gray

Write-Host ''
Write-Host 'Before publishing, install THIS file on a freshly flashed Mabu:' -ForegroundColor Yellow
Write-Host "  adb install -r `"$final`"" -ForegroundColor Gray
Write-Host '  (then follow sample-apps/INSTALL-A-SAMPLE-APP.md exactly as a user would)' -ForegroundColor Gray
Write-Host ''
Write-Host 'Then attach it to the release:' -ForegroundColor Yellow
Write-Host "  gh release upload <tag> `"$final`" `"$final.sha256`"" -ForegroundColor Gray
