param(
    [string]$Flutter = ''
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
& (Join-Path $PSScriptRoot 'prepare_plugin_junctions.ps1') -Flutter $Flutter

if ([string]::IsNullOrWhiteSpace($Flutter)) {
    $Flutter = Join-Path $env:USERPROFILE 'Tools\flutter\bin\flutter.bat'
}

Push-Location $projectRoot
try {
    & $Flutter build windows --release
    if ($LASTEXITCODE -ne 0) { throw 'Windows release build failed.' }
    $dist = Join-Path $projectRoot 'dist'
    New-Item -ItemType Directory -Path $dist -Force | Out-Null
    Compress-Archive -Path 'build\windows\x64\runner\Release\*' `
        -DestinationPath (Join-Path $dist 'TorBridge-Windows-x64-1.0.0.zip') `
        -CompressionLevel Optimal -Force
} finally {
    Pop-Location
}

