param(
    [string]$Flutter = ''
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
    Invoke-NativeCommand -Executable $Flutter -Arguments @('build', 'windows', '--release')
    $dist = Join-Path $projectRoot 'dist'
    New-Item -ItemType Directory -Path $dist -Force | Out-Null
    $versionLine = Select-String -LiteralPath 'pubspec.yaml' -Pattern '^version:\s*(\S+)'
    if ($null -eq $versionLine) { throw 'Could not read app version.' }
    $fullVersion = $versionLine.Matches[0].Groups[1].Value
    $versionName = $fullVersion.Split('+')[0]
    Set-Content -LiteralPath 'build\windows\x64\runner\Release\VERSION.txt' -Value $fullVersion -Encoding utf8
    Compress-Archive -Path 'build\windows\x64\runner\Release\*' `
        -DestinationPath (Join-Path $dist "TorBridge-Windows-x64-$versionName.zip") `
        -CompressionLevel Optimal -Force
} finally {
    Pop-Location
}
