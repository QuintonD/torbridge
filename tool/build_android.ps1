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
    # Restrict ABIs without --split-per-abi, preserving the normal version code
    # so switching between universal and ARM64 updates remains possible.
    if ($Arm64) { $buildArguments += @('--target-platform', 'android-arm64') }
    & $Flutter @buildArguments
    if ($LASTEXITCODE -ne 0) { throw 'Android release build failed.' }
    $dist = Join-Path $projectRoot 'dist'
    New-Item -ItemType Directory -Path $dist -Force | Out-Null
    $versionLine = Select-String -LiteralPath 'pubspec.yaml' -Pattern '^version:\s*([^+\s]+)'
    if ($null -eq $versionLine) { throw 'Could not read the app version from pubspec.yaml.' }
    $versionName = $versionLine.Matches[0].Groups[1].Value
    $artifactSuffix = if ($Arm64) { '-arm64' } else { '' }
    Copy-Item -LiteralPath 'build\app\outputs\flutter-apk\app-release.apk' `
        -Destination (Join-Path $dist "TorBridge-Android-$versionName$artifactSuffix.apk") -Force
} finally {
    Pop-Location
}
