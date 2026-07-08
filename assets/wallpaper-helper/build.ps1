# build.ps1 -- build the GCB wallpaper helper APK (no Gradle; raw build-tools).
# Output: <worktree>/apks/gcb-wallpaper.apk. Repeatable; run after changing the
# source or regenerating res/drawable-nodpi/gcb_wallpaper.png (make_wallpaper.py).
# NOTE: 'Continue' (not 'Stop') -- the build tools (javac deprecation Notes, etc.)
# write to stderr, which under 'Stop' becomes a fatal NativeCommandError. Real
# failures are caught by the explicit `if ($LASTEXITCODE) { throw }` checks below.
$ErrorActionPreference = 'Continue'
$here = $PSScriptRoot
$root = (Resolve-Path (Join-Path $here '..\..')).Path
$sdk  = Join-Path $env:LOCALAPPDATA 'Android\Sdk'

# pick the highest build-tools and any installed platform android.jar
$bt = (Get-ChildItem (Join-Path $sdk 'build-tools') -Directory | Sort-Object Name -Descending | Select-Object -First 1).FullName
$androidJar = (Get-ChildItem (Join-Path $sdk 'platforms') -Filter android.jar -Recurse | Select-Object -First 1).FullName
$aapt = Join-Path $bt 'aapt.exe'; $d8 = Join-Path $bt 'd8.bat'
$zipalign = Join-Path $bt 'zipalign.exe'; $apksigner = Join-Path $bt 'apksigner.bat'
Write-Host "build-tools: $bt"; Write-Host "android.jar: $androidJar"

$work = Join-Path $here 'build'
Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $work, "$work\gen", "$work\classes" | Out-Null
$out = Join-Path $root 'apks\gcb-wallpaper.apk'
New-Item -ItemType Directory -Force (Split-Path $out) | Out-Null

# 1. package resources + manifest -> base.apk, generate R.java
& $aapt package -f -M "$here\AndroidManifest.xml" -S "$here\res" -I $androidJar -J "$work\gen" -F "$work\base.apk"
if ($LASTEXITCODE) { throw "aapt package failed" }

# 2. compile (source/target 8 for dex; android.* comes from -classpath android.jar)
$rjava = (Get-ChildItem "$work\gen" -Recurse -Filter R.java).FullName
$src   = (Get-ChildItem "$here\src" -Recurse -Filter *.java).FullName
& javac -source 8 -target 8 -nowarn -classpath $androidJar -d "$work\classes" $rjava $src
if ($LASTEXITCODE) { throw "javac failed" }

# 3. dex
$classes = (Get-ChildItem "$work\classes" -Recurse -Filter *.class).FullName
& $d8 --min-api 21 --lib $androidJar --output $work @classes
if ($LASTEXITCODE) { throw "d8 failed" }

# 4. add classes.dex into the apk (entry name = file name; run from $work)
Copy-Item "$work\base.apk" "$work\app.apk" -Force
Push-Location $work
try { & $aapt add 'app.apk' 'classes.dex' } finally { Pop-Location }
if ($LASTEXITCODE) { throw "aapt add failed" }

# 5. align
& $zipalign -f 4 "$work\app.apk" "$work\app-aligned.apk"
if ($LASTEXITCODE) { throw "zipalign failed" }

# 6. sign (committed debug keystore -> reproducible signature across rebuilds)
$ks = Join-Path $here 'gcb-debug.keystore'
if (-not (Test-Path $ks)) {
    & keytool -genkeypair -keystore $ks -storepass android -keypass android -alias gcb `
        -keyalg RSA -keysize 2048 -validity 10000 -dname 'CN=Get Circuit Bent, O=Get Circuit Bent'
    if ($LASTEXITCODE) { throw 'keytool failed' }
}
& $apksigner sign --ks $ks --ks-pass pass:android --key-pass pass:android --min-sdk-version 21 --out $out "$work\app-aligned.apk"
if ($LASTEXITCODE) { throw 'apksigner sign failed' }
& $apksigner verify $out
Write-Host "Built: $out" -ForegroundColor Green
& $aapt dump badging $out | Select-String 'package:|uses-permission|launchable|application-label:'
