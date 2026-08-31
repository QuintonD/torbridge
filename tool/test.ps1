param(
    [string]$Flutter = '',
    [string]$AndroidDevice = ''
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
& (Join-Path $PSScriptRoot 'prepare_plugin_junctions.ps1') -Flutter $Flutter

if ([string]::IsNullOrWhiteSpace($Flutter)) {
    $Flutter = Join-Path $env:USERPROFILE 'Tools\flutter\bin\flutter.bat'
}

Push-Location $projectRoot
try {
    & $Flutter analyze
    if ($LASTEXITCODE -ne 0) { throw 'Static analysis failed.' }
    & $Flutter test test
    if ($LASTEXITCODE -ne 0) { throw 'Host tests failed.' }
    if (-not [string]::IsNullOrWhiteSpace($AndroidDevice)) {
        & $Flutter test integration_test\app_test.dart -d $AndroidDevice
        if ($LASTEXITCODE -ne 0) { throw 'Android integration test failed.' }
    }
} finally {
    Pop-Location
}

