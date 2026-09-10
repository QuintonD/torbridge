# Android interrupted download recovery — 1.2.10

The Pixel report after 1.2.9 exposed an incorrect error-code mapping. TorBridge
rendered Android reason **1008** as "the file already exists". Android defines
1008 as **ERROR_CANNOT_RESUME**; **ERROR_FILE_ALREADY_EXISTS** is **1009**.
Consequently, an interrupted transfer was described as a local file conflict and
excluded from the existing source-refresh and TorBox recovery path. The screenshot
does not establish why the original connection was interrupted.

## Changes

- Correct the mapping and allow cannot-resume errors through the bounded source
  recovery sequence: refreshed source, suitable alternative, fresh TorBox link.
  Correct the saved error text in older records without changing new genuine
  file-conflict records.
- Retire the previous Android download ID before a manual retry starts from zero.
  Keep the existing storage recheck for unavailable files and separate transfer
  destinations. Repeated retry taps still start only one transfer.
- Limit retry/recovery source lookup to 30 seconds, then continue using the saved
  source or TorBox reference. Limit initial link preparation to 60 seconds and
  configure connect/send/receive timeouts on addon and TorBox API requests.
- Check cancellation before enqueuing, including responses arriving after the
  user removes a preparing download.
- Show Android's pending and paused reasons on download cards, including network,
  Wi-Fi and system retry waits, and clear those messages when bytes resume.
- Surface Android deletion failures instead of dropping the app record. Serialize
  deletion with retention and follow journaled moves when an old path is supplied.
  Deleting an already-removed Download Manager record remains idempotent.

These changes do not impose a total time limit on multi-gigabyte video transfers.
The existing library retention from 1.2.9 remains in place.

## Verification

- Static analysis is clean and all 56 host tests pass. Regressions cover saved
  error migration, 1008 recovery through a fresh TorBox link, actual 1009 handling,
  duplicate retry, a stalled addon, cancellation before a late response, Android
  wait messages and deletion failure propagation.
- Three native integration tests pass on the API 36 emulator. A local HTTP
  fixture deliberately closes a response early without an ETag; real Download
  Manager returns 1008. The test then cancels the failed job, downloads the same
  filename successfully, deletes it, and downloads that name again to a new path.
- Existing native tests continue to verify completion-receiver retention,
  survival of Download Manager record removal, file/content streaming ranges,
  legacy migration and deletion through a pre-move path.

No Pixel 7a is connected to this workspace; emulator transfer fixtures do not
establish real-device network reliability or video decoding support.

## Update artifacts

Both release APKs use version 1.2.10 / code 13 and the same signing certificate
as 1.2.9. APK signature verification passed for both. The ARM64 build contains
only `arm64-v8a` native libraries and is approximately 42.4 MB; the universal
build is approximately 120.8 MB.

Install `dist/TorBridge-Android-1.2.10-arm64.apk` over the existing app on the
Pixel, then retry one affected download while online and confirm playback.
Do not uninstall first. The update does not restore previously deleted bytes.

SHA-256:

- ARM64: `0cf00d1167932dd6c10cb5149df697f222d6327e8ac8fa82fdc95f4f4222587d`
- Universal: `2c7d49f45fe6e3dc400a7370f9c1eace0cda0f39b37cbdff7809c55a27be63e5`

Reference: [Android DownloadManager constants](https://developer.android.com/reference/android/app/DownloadManager#ERROR_CANNOT_RESUME).
