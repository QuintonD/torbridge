$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$installDir = Join-Path $repoRoot 'dist\TorBridge-Windows-x64-1.0.0'
$releaseDir = Join-Path $repoRoot 'build\windows\x64\runner\Release'
$configDir = Join-Path $env:APPDATA 'app.torbridge'
$backupRoot = Join-Path $repoRoot 'backups'
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backupFile = Join-Path $backupRoot "TorBridge-connections-$timestamp.zip"

if (-not (Test-Path -LiteralPath (Join-Path $releaseDir 'torbridge.exe'))) {
  throw "Release bundle not found at $releaseDir"
}
if (-not (Test-Path -LiteralPath $installDir)) {
  throw "Existing installation not found at $installDir"
}

New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
if (Test-Path -LiteralPath $configDir) {
  Compress-Archive -LiteralPath $configDir -DestinationPath $backupFile -CompressionLevel Optimal
}

Copy-Item -LiteralPath (Join-Path $releaseDir 'torbridge.exe') -Destination $installDir -Force
Copy-Item -LiteralPath (Join-Path $releaseDir 'flutter_windows.dll') -Destination $installDir -Force
Copy-Item -LiteralPath (Join-Path $releaseDir 'data') -Destination $installDir -Recurse -Force

$versionMarker = Join-Path $installDir 'VERSION.txt'
Set-Content -LiteralPath $versionMarker -Value 'TorBridge 1.2.0+3' -Encoding utf8

[pscustomobject]@{
  InstallDirectory = $installDir
  Executable = Join-Path $installDir 'torbridge.exe'
  ConfigDirectory = $configDir
  Backup = if (Test-Path -LiteralPath $backupFile) { $backupFile } else { $null }
  Version = '1.2.0+3'
}
