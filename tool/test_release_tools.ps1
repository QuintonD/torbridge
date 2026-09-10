$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'native_command.ps1')
$testRoot = [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $PSScriptRoot) '.dart_tool'))
$fixture = Join-Path $testRoot ('release-tools-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture | Out-Null
try {
    $installed = Join-Path $fixture 'installed'
    $release = Join-Path $fixture 'release'
    New-Item -ItemType Directory -Path $installed, (Join-Path $release 'data\flutter_assets') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $installed 'torbridge.exe') -Value 'old-exe'
    Set-Content -LiteralPath (Join-Path $installed 'obsolete.dll') -Value 'old-plugin'
    Set-Content -LiteralPath (Join-Path $release 'torbridge.exe') -Value 'new-exe'
    Set-Content -LiteralPath (Join-Path $release 'flutter_windows.dll') -Value 'flutter'
    Set-Content -LiteralPath (Join-Path $release 'new_plugin.dll') -Value 'new-plugin'
    Set-Content -LiteralPath (Join-Path $release 'data\flutter_assets\asset.txt') -Value 'new-asset'
    Set-Content -LiteralPath (Join-Path $release 'VERSION.txt') -Value '9.8.7+654'
    $result = & (Join-Path $PSScriptRoot 'update_local_windows.ps1') -InstallDirectory $installed -ReleaseDirectory $release
    if ($result.Version -ne '9.8.7+654') { throw 'Update version did not come from the release.' }
    if (-not (Test-Path -LiteralPath (Join-Path $installed 'new_plugin.dll'))) { throw 'Plugin DLL was not installed.' }
    if (-not (Test-Path -LiteralPath (Join-Path $installed 'data\flutter_assets\asset.txt'))) { throw 'Assets were not installed.' }
    if (Test-Path -LiteralPath (Join-Path $installed 'obsolete.dll')) { throw 'An obsolete DLL remains in the new bundle.' }
    if ((Get-Content -LiteralPath (Join-Path $result.Backup 'torbridge.exe')).Trim() -ne 'old-exe') { throw 'Original installation was not preserved.' }
    $rejected = $false
    try { & (Join-Path $PSScriptRoot 'update_local_windows.ps1') -InstallDirectory $release -ReleaseDirectory $release } catch { $rejected = $true }
    if (-not $rejected) { throw 'Overlapping update paths were accepted.' }

    $warning = Join-Path $fixture 'warning.cmd'
    Set-Content -LiteralPath $warning -Encoding ascii -Value "@echo off`r`necho Fixture warning 1>&2`r`nexit /b 0"
    Invoke-NativeCommand -Executable $warning
    if ($NativeExitCode -ne 0) { throw 'Warning was treated as failure.' }
    Set-Content -LiteralPath $warning -Encoding ascii -Value "@echo off`r`necho Fixture failure 1>&2`r`nexit /b 7"
    $rejected = $false
    try { Invoke-NativeCommand -Executable $warning } catch { $rejected = $true }
    if (-not $rejected) { throw 'A failed native command was accepted.' }
    Write-Output 'Release tooling fixtures passed: full bundle, backup, dynamic version, path guards, stderr and exit status.'
} finally {
    $resolvedFixture = [IO.Path]::GetFullPath($fixture)
    if (-not $resolvedFixture.StartsWith($testRoot.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Unsafe fixture cleanup path.'
    }
    Remove-Item -LiteralPath $resolvedFixture -Recurse -Force
}
