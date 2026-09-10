param(
    [Parameter(Mandatory = $true)][string]$InstallDirectory,
    [string]$ReleaseDirectory = ''
)
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ReleaseDirectory)) {
    $ReleaseDirectory = Join-Path $repoRoot 'build\windows\x64\runner\Release'
}
$installDir = (Resolve-Path -LiteralPath $InstallDirectory).ProviderPath.TrimEnd('\')
$releaseDir = (Resolve-Path -LiteralPath $ReleaseDirectory).ProviderPath.TrimEnd('\')
foreach ($bundle in @($installDir, $releaseDir)) {
    if (-not (Test-Path -LiteralPath (Join-Path $bundle 'torbridge.exe') -PathType Leaf)) {
        throw "TorBridge executable missing in $bundle"
    }
    if ((Get-Item -LiteralPath $bundle).Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw 'Use a real installation directory, not a junction or symlink.'
    }
}
if ($installDir -eq $releaseDir -or $releaseDir.StartsWith($installDir + '\', [StringComparison]::OrdinalIgnoreCase) -or
    $installDir.StartsWith($releaseDir + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The build and installation directories must be separate.'
}
foreach ($required in @('flutter_windows.dll', 'data\flutter_assets', 'VERSION.txt')) {
    if (-not (Test-Path -LiteralPath (Join-Path $releaseDir $required))) { throw "Release bundle missing $required" }
}
$version = (Get-Content -LiteralPath (Join-Path $releaseDir 'VERSION.txt') -Raw).Trim()
if ($version -notmatch '^\d+\.\d+\.\d+\+\d+$') { throw 'Invalid release version marker.' }
# App data is stored outside the program folder and is never changed here.
# Stage the complete bundle, including all plugin DLLs, before moving anything.
$parent = Split-Path -Parent $installDir
if ([string]::IsNullOrWhiteSpace($parent)) { throw 'Cannot update a filesystem root.' }
$nonce = [Guid]::NewGuid().ToString('N')
$stageDir = [IO.Path]::GetFullPath((Join-Path $parent ".torbridge-update-$nonce"))
$backupDir = [IO.Path]::GetFullPath((Join-Path $parent "TorBridge-backup-$nonce"))
foreach ($target in @($installDir, $stageDir, $backupDir)) {
    if (-not $target.StartsWith($parent.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) -or
        $target -eq $parent) { throw "Unsafe update target: $target" }
}
New-Item -ItemType Directory -Path $stageDir | Out-Null
Get-ChildItem -LiteralPath $releaseDir -Force | ForEach-Object {
    Copy-Item -LiteralPath $_.FullName -Destination $stageDir -Recurse -Force
}
try {
    Move-Item -LiteralPath $installDir -Destination $backupDir
    Move-Item -LiteralPath $stageDir -Destination $installDir
} catch {
    if (-not (Test-Path -LiteralPath $installDir) -and (Test-Path -LiteralPath $backupDir)) {
        Move-Item -LiteralPath $backupDir -Destination $installDir
    }
    throw "Update failed; close TorBridge before updating. $($_.Exception.Message)"
}
[pscustomobject]@{ InstallDirectory = $installDir; Backup = $backupDir; Version = $version }
