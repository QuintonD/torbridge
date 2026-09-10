# Install and update TorBridge

Get builds from [GitHub Releases](https://github.com/QuintonD/torbridge/releases).
Each release describes its changes and includes versioned files and checksums.

## Android

1. Download the **ARM64 APK** for a Pixel 7a, Galaxy S25, or another ARM64 phone.
   Choose the **universal APK** if your device needs a different architecture.
2. Open the APK and allow installation from your browser or file manager if
   Android asks. Choose **Update** when TorBridge is already installed.
3. Open TorBridge after the update and run **Diagnostics → Run checks**.

The APK is the installer and the update file. There is no separate patch file or
automatic updater. **Do not uninstall or clear app storage before updating**:
app-private downloads and settings can be removed by those actions. Both APK
variants use the same application ID and certificate, so switching variants
does not require uninstalling.

Updating preserves existing settings and records, but cannot restore video bytes
already deleted from the phone. If a video remains under **Needs attention**,
retry one download while online and confirm playback before retrying the rest.

If Android refuses an update, note its exact message and your currently installed
version. Do not uninstall as a first troubleshooting step. Report the details in
[a bug report](https://github.com/QuintonD/torbridge/issues/new?template=bug_report.yml).

## Windows

Download the Windows ZIP from the release linked on the repository home page.
Android-only releases do not include a new Windows build.

Close TorBridge, extract the entire new ZIP into a new folder, and run
`torbridge.exe` there. Keep its DLLs and `data` folder beside the executable.
Keep the older application folder until the update launches successfully.

## Check a download

New releases include `SHA256SUMS.txt`. On Windows, compare its entry with:

```powershell
Get-FileHash -Algorithm SHA256 -LiteralPath .\TorBridge-Android-1.2.10-arm64.apk
```

Only install release files from this repository. The files GitHub labels
**Source code (zip)** and **Source code (tar.gz)** are developer source archives,
not installable applications.
