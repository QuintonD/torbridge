# Android download recovery — 1.2.8

The Pixel 7a report shows 19 completed download records whose stored local files
cannot be found, followed by failures in embedded and external playback. The
user installed the update over the existing app. The screenshots establish
unavailable paths, but do not establish whether the files were removed, moved,
or became inaccessible. No Pixel was connected during this investigation.

## Changes

- Resolve local sources by opening them, including `file://` and `content://`
  URIs. For Android jobs, also check the saved platform path, Download Manager's
  `COLUMN_LOCAL_URI`, and its content URI. A successful transfer is not marked
  complete unless its local source can be opened and contains data.
- Check completed records at startup, in Diagnostics, and before launching
  downloaded content. Persist recovered paths. Keep unreadable records and
  their original paths/IDs under **Needs attention**, with an explicit retry.
- Recheck storage before retrying an unavailable file, so a recovered file does
  not trigger a redundant download. Exclude unavailable records from the local
  addon and from the set of episodes already downloaded.
- Serve Android content URIs through the native bridge with byte ranges and
  HEAD support. Previously the bridge passed every source to `File`, making
  older content-URI downloads fail regardless of their actual availability.

The automatic checks neither delete files nor download replacements. This
change cannot restore video bytes that are no longer present. It does not
establish the cause of all 19 unavailable Pixel files or validate its codecs.

## Validation

- Android release APK built as `app.torbridge.torbridge`, version `1.2.8` / build
  `11`; APK signature verification passed and its certificate matches the local
  1.2.7 artifact, allowing installation as an update.
- 45 host tests passed, including startup reconciliation, preserving unavailable
  records, reappearing storage, a file disappearing before playback, and Android
  completion checks using mocked platform responses.
- Native Android integration passed on an API 34 emulator. The test uses a
  generated 1 KiB fixture and real Download Manager, verifies stale/null-path
  recovery, and tests file paths, file URIs and content URIs through the native
  bridge: full bytes, explicit and suffix ranges, HEAD, and invalid ranges.
  After deletion it verifies both path and content URI resolve as unavailable.
  This checks storage and streaming, not video decoding.
- Debug-only network configuration allows the on-device HTTP fixture at
  `127.0.0.1`. Release network policy is unchanged.

To repeat the native test:

```powershell
flutter test integration_test/download_recovery_test.dart -d <android-device>
```

On the Pixel, install the APK over the existing app and run Diagnostics. Check
whether old downloads recover; if any remain unavailable, retry one while
online and test playback before replacing the rest.

Android API reference: [DownloadManager](https://developer.android.com/reference/android/app/DownloadManager).
