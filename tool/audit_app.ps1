param([string]$Flutter = '')
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'native_command.ps1')
if ([string]::IsNullOrWhiteSpace($Flutter)) {
    $Flutter = Join-Path $env:USERPROFILE 'Tools\flutter\bin\flutter.bat'
}
Push-Location (Split-Path -Parent $PSScriptRoot)
try {
    Invoke-NativeCommand -Executable $Flutter -Arguments @('test', '--no-pub', 'test/app_state_test.dart', '--plain-name', 'AUDIT', '--reporter', 'expanded')
} finally { Pop-Location }
