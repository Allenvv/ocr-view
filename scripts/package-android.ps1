param(
    [string]$Flutter = 'flutter',
    [string]$SdkRoot = $(if ($env:ANDROID_SDK_ROOT) { $env:ANDROID_SDK_ROOT } else { $env:ANDROID_HOME }),
    [string]$BuildToolsVersion = '35.0.0',
    [string]$GradleInitScript,
    [switch]$SkipLintVitalRelease
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
function Invoke-Checked([string]$Tool, [string[]]$Arguments) {
    & $Tool @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Tool failed (exit $LASTEXITCODE)" }
}
Push-Location $root
try {
    if (-not $SdkRoot) { throw 'Set ANDROID_SDK_ROOT or supply -SdkRoot.' }
    $env:ANDROID_HOME = $SdkRoot
    $env:ANDROID_SDK_ROOT = $SdkRoot
    $tools = Join-Path $SdkRoot "build-tools/$BuildToolsVersion"
    $signer = Join-Path $tools 'apksigner.bat'
    $aapt = Join-Path $tools 'aapt.exe'
    if (!(Test-Path $signer) -or !(Test-Path $aapt)) { throw "Missing signing or inspection tools in $tools" }
    $match = [regex]::Match((Get-Content -Raw pubspec.yaml), '(?m)^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$')
    if (!$match.Success) { throw 'Expected version: x.y.z+build in pubspec.yaml.' }
    $versionName = $match.Groups[1].Value
    $versionCode = $match.Groups[2].Value
    if ($GradleInitScript) {
        $init = (Resolve-Path -LiteralPath $GradleInitScript).Path
        $flutterHome = Split-Path -Parent (Split-Path -Parent (Get-Command $Flutter).Source)
        @("flutter.sdk=$($flutterHome.Replace('\','\\'))", "sdk.dir=$($SdkRoot.Replace('\','\\'))", 'flutter.buildMode=release', "flutter.versionName=$versionName", "flutter.versionCode=$versionCode") | Set-Content -Encoding ascii android/local.properties
        Push-Location android
        try {
            $gradleArgs = @('--init-script', $init, '--console=plain', '--max-workers=4', '-Pkotlin.incremental=false', '-Pkotlin.compiler.execution.strategy=in-process', '-Ptarget-platform=android-arm,android-arm64,android-x64', '-Ptarget=lib/main.dart', '-Pbase-application-name=android.app.Application', '-Pdart-obfuscation=false', '-Ptrack-widget-creation=true', '-Ptree-shake-icons=true', ':app:assembleRelease')
            if ($SkipLintVitalRelease) { $gradleArgs += @('-x', ':app:lintVitalRelease') }
            Invoke-Checked '.\gradlew.bat' $gradleArgs
        } finally { Pop-Location }
        $apk = 'build/app/outputs/apk/release/app-release.apk'
    } else {
        Invoke-Checked $Flutter @('build', 'apk', '--release')
        $apk = 'build/app/outputs/flutter-apk/app-release.apk'
    }
    Invoke-Checked $signer @('verify','--verbose',$apk)
    $package = & $aapt dump badging $apk | Select-String '^package:'
    if ($LASTEXITCODE -ne 0 -or "$package" -notmatch "versionCode='$versionCode' versionName='$([regex]::Escape($versionName))'") { throw "APK version mismatch: $package" }
    New-Item -ItemType Directory -Force artifacts | Out-Null
    $output = Join-Path $root "artifacts/PM25-Capture-v$versionName.apk"
    Copy-Item -LiteralPath $apk -Destination $output
    Get-FileHash -LiteralPath $output -Algorithm SHA256
} finally { Pop-Location }
