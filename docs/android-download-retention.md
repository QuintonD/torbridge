# Android download retention — 1.2.9

Android documents that Download Manager downloads outside public Downloads can
be removed by idle cleanup after seven days without modification. TorBridge
1.2.7 and 1.2.8 left completed downloads in app-specific Movies storage at the
path still owned by Download Manager. Version 1.2.8 detected unavailable files
and offered retries but did not fix their exposure to that cleanup.

This is consistent with the Pixel report and the user's confirmation that its
downloads were at least a week old. Recent app interaction and newer downloads
on another phone do not establish why that phone's older files survived. We do
not have the Pixel's historical logs to prove which operation removed its files.

## Retaining video data

New transfers use unique directories under `Movies/TorBridge/Transfers`.
Completed files are moved into `Movies/TorBridge/Library` at a path that Download
Manager does not own. The native completion receiver performs this even without
Flutter polling; startup, diagnostics and playback also migrate readable legacy
files. Public download locations remain unchanged.

The move is a same-filesystem rename: it does not duplicate multi-gigabyte videos
or need another full file's worth of free space. A synchronous journal maps the
original path to the new location before the move. After a process interruption,
TorBridge can recover from an old Flutter path or platform download ID. Every
new transfer has a unique original path, so repeated filenames cannot resolve
to an older retained version. Receiver, resolution and cancellation operations
serialize access to prevent a concurrent rename from escaping a user deletion.

If a move fails, the original is preserved and remains playable. Downloads shows
a warning, and Diagnostics reports the storage protection failure. Running the
checks again retries protection without re-downloading.

Retries now enter the preparing state immediately and ignore repeated taps for
the same job. Each transfer has its own destination directory, avoiding conflicts
with previous attempts. Android file/storage errors are no longer incorrectly
attributed to the stream server.

Correction in 1.2.10: the earlier interpretation of the Pixel screenshot as a
destination conflict was incorrect. Versions through 1.2.9 mislabeled Android
reason 1008 (cannot resume) as "file already exists"; actual destination conflicts
use 1009. See [interrupted download recovery](android-download-retry.md).

## Verification

Static analysis is clean and all 47 host tests pass, including the storage-error
message and duplicate-retry regression tests.

The native API 34 integration tests exercise real Download Manager transfers,
completion without Dart download polling, migration of a legacy file without a
platform ID, recovery using the pre-move path, repeated filenames, and explicit
deletion. They delete the original Download Manager content URI and verify that
the independent library bytes remain intact and the transfer can still be
resumed from native metadata. File paths, file URIs and FileProvider content
URIs also pass full/range/HEAD streaming checks.

This tests survival of the original record's deletion rather than advancing a
device clock seven days, and does not test Pixel-specific video decoding or
force-stopped-app broadcast delivery. If Android prevents the completion receiver
from running, protection is retried when TorBridge next opens.

The smaller ARM64 APK excludes other processor architectures; it contains the
same app and fixes as the universal APK. Both use version code 12 and the same
signing key as 1.2.8, allowing normal in-place updates.

Install 1.2.9 over the existing app and open it once on both phones. Check
Diagnostics for storage protection errors. Already-deleted video bytes still
need a new download; the fix protects readable existing files and new transfers.

References: [DownloadManager.Request](https://developer.android.com/reference/android/app/DownloadManager.Request#setVisibleInDownloadsUi(boolean))
and [Android's idle cleanup implementation](https://android.googlesource.com/platform/packages/providers/DownloadProvider/+/master/src/com/android/providers/downloads/DownloadIdleService.java).
