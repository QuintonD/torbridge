param(
    [string]$Flutter = ''
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'native_command.ps1')
$projectRoot = Split-Path -Parent $PSScriptRoot

if ([string]::IsNullOrWhiteSpace($Flutter)) {
    $flutterCommand = Get-Command flutter.bat -ErrorAction SilentlyContinue
    if ($null -eq $flutterCommand) {
        $flutterCommand = Get-Command flutter -ErrorAction SilentlyContinue
    }
    if ($null -ne $flutterCommand) {
        $Flutter = $flutterCommand.Source
    } else {
        $Flutter = Join-Path $env:USERPROFILE 'Tools\flutter\bin\flutter.bat'
    }
}

if (-not (Test-Path -LiteralPath $Flutter)) {
    throw "Flutter was not found at '$Flutter'. Pass -Flutter with its full path."
}

Push-Location $projectRoot
try {
    Invoke-NativeCommand -Executable $Flutter -Arguments @('pub', 'get') -AllowFailure
    $metadataPath = Join-Path $projectRoot '.flutter-plugins-dependencies'
    $pubGetNeedsRetry = $NativeExitCode -ne 0
    if ($pubGetNeedsRetry -and -not (Test-Path -LiteralPath $metadataPath)) {
        throw 'flutter pub get failed before plugin metadata was generated.'
    }

    # On Windows without symlink privileges Flutter can finish dependency
    # resolution and write plugin metadata, then fail while creating plugin
    # symlinks. Build equivalent junctions from that metadata and retry once.
    $metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
    $junctionRoot = Join-Path $projectRoot 'windows\flutter\ephemeral\.plugin_symlinks'
    New-Item -ItemType Directory -Path $junctionRoot -Force | Out-Null

    foreach ($plugin in $metadata.plugins.windows) {
        # Flutter's JSON contains doubled separators on this Windows setup.
        $target = $plugin.path.Replace('\\', '\')
        $link = Join-Path $junctionRoot $plugin.name
        if (Test-Path -LiteralPath $link) { continue }
        New-Item -ItemType Junction -Path $link -Target $target | Out-Null
    }

    if ($pubGetNeedsRetry) {
        Invoke-NativeCommand -Executable $Flutter -Arguments @('pub', 'get') -AllowFailure
        if ($NativeExitCode -ne 0) {
            throw 'flutter pub get still failed after plugin junctions were prepared.'
        }
    }
} finally {
    Pop-Location
}
