param(
    [string]$Flutter = '',
    [string]$AndroidDevice = ''
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'native_command.ps1')
$projectRoot = Split-Path -Parent $PSScriptRoot
& (Join-Path $PSScriptRoot 'prepare_plugin_junctions.ps1') -Flutter $Flutter

if ([string]::IsNullOrWhiteSpace($Flutter)) {
    $Flutter = Join-Path $env:USERPROFILE 'Tools\flutter\bin\flutter.bat'
}

Push-Location $projectRoot
try {
    Invoke-NativeCommand -Executable $Flutter -Arguments @('analyze')
    if ($NativeExitCode -ne 0) { throw 'Static analysis failed.' }
    Invoke-NativeCommand -Executable $Flutter -Arguments @('test', 'test')
    if ($NativeExitCode -ne 0) { throw 'Host tests failed.' }
    if (-not [string]::IsNullOrWhiteSpace($AndroidDevice)) {
        Invoke-NativeCommand -Executable $Flutter -Arguments @('test', 'integration_test/app_test.dart', '-d', $AndroidDevice)
        Invoke-NativeCommand -Executable $Flutter -Arguments @('test', 'integration_test/download_recovery_test.dart', '-d', $AndroidDevice)
        if ($NativeExitCode -ne 0) { throw 'Android integration test failed.' }
    }
} finally {
    Pop-Location
}

