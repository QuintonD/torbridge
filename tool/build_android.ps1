param(
    [string]$Flutter = '',
    [switch]$Arm64
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
& (Join-Path $PSScriptRoot 'prepare_plugin_junctions.ps1') -Flutter $Flutter

if ([string]::IsNullOrWhiteSpace($Flutter)) {
    $Flutter = Join-Path $env:USERPROFILE 'Tools\flutter\bin\flutter.bat'
}

Push-Location $projectRoot
try {
    $buildArguments = @('build', 'apk', '--release')
    # ABI splitting also filters bundled plugin libraries. Keep the normal
    # version code so switching back to a universal update remains possible.
    if ($Arm64) {
        $buildArguments += @('--target-platform', 'android-arm64', '--split-per-abi',
            '-P', 'force-version-code-ignoring-abi=true')
    }
    & $Flutter @buildArguments
    if ($LASTEXITCODE -ne 0) { throw 'Android release build failed.' }
    $dist = Join-Path $projectRoot 'dist'
    New-Item -ItemType Directory -Path $dist -Force | Out-Null
    $versionLine = Select-String -LiteralPath 'pubspec.yaml' -Pattern '^version:\s*([^+\s]+)'
    if ($null -eq $versionLine) { throw 'Could not read the app version from pubspec.yaml.' }
    $versionName = $versionLine.Matches[0].Groups[1].Value
    $artifactSuffix = if ($Arm64) { '-arm64' } else { '' }
    $apkName = if ($Arm64) { 'app-arm64-v8a-release.apk' } else { 'app-release.apk' }
    Copy-Item -LiteralPath (Join-Path 'build\app\outputs\flutter-apk' $apkName) `
        -Destination (Join-Path $dist "TorBridge-Android-$versionName$artifactSuffix.apk") -Force
} finally {
    Pop-Location
}
