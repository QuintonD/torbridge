function Invoke-NativeCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Executable,
        [string[]]$Arguments = @(),
        [switch]$AllowFailure
    )
    # Windows PowerShell can promote ordinary native stderr to an exception.
    # Keep PowerShell filesystem errors terminating, but use native exit codes.
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & $Executable @Arguments
        $nativeExit = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousPreference
    }
    $script:NativeExitCode = $nativeExit
    if ($nativeExit -ne 0 -and -not $AllowFailure) {
        throw "Native command failed with exit code ${nativeExit}: $Executable"
    }
}
