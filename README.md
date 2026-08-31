# TorBridge

TorBridge is a movie-first Android and Windows companion for a TorBox +
AIOStreams + Trakt setup. Search once, let the app rank the available files,
download the best match, play it offline, and keep watched state in one UI.

The current v1 build is usable without credentials in demo mode. Live mode
uses your configured AIOStreams manifest and TorBox account; Trakt is optional.

## Installable builds

- `dist/TorBridge-Android-1.0.0.apk` — sideloadable Android APK (Android 7+
  by Flutter's current minimum; tested on API 30, 34, and 36).
- `dist/TorBridge-Windows-x64-1.0.0.zip` — extract the complete archive and run
  `torbridge.exe`. Do not move the executable away from its adjacent DLL and
  `data` files.

The Android artifact is an optimized release build signed with a development
key. It is appropriate for personal sideloading, not Play Store distribution.

## First run

1. Open **Settings → Connect services**.
2. Paste the configured AIOStreams manifest URL you already use with Stremio.
   TorBridge accepts `stremio://` and HTTPS manifest URLs and preserves the
   configuration path.
3. Paste your TorBox API token and choose **Check & save**. Both endpoints are
   validated before live mode is enabled.
4. Optional: create a personal Trakt API application, enter its client ID and
   secret, save, then choose **Authorize Trakt** and approve the one-time code.
5. Set preferred audio, subtitles, quality, size limit, HDR, and whether the
   preferred audio is mandatory.

Search for a movie, inspect the explanation under **Recommended download**, and
choose **Download best match**. On Windows files go to
`Downloads\TorBridge`. Android uses the system Download Manager and normally
saves to `Downloads/TorBridge`, with app-specific Movies storage as a fallback
on constrained devices.

Only download or play media you are authorized to access.

## What chooses the link

TorBridge parses Stremio stream metadata, verifies unknown torrent cache states
with one batched TorBox request, removes candidates that violate hard rules,
then scores the rest. The ranking considers:

- TorBox instant-cache status;
- preferred and allowed resolution;
- ordered audio and subtitle languages;
- HEVC, AV1, and H.264 codec preference;
- HDR preference;
- maximum file size;
- release quality, while rejecting CAM, telesync, and screener sources.

Every winner displays its positive reasons. Suitable alternatives remain
visible, but choosing one manually is not required.

## Playback and history

The embedded MPV-based player handles both direct and downloaded files. Trakt
receives start, pause, and stop scrobbles; a stop at 80% or later marks the
movie watched. Manual **Mark watched** also syncs. Expired Trakt access tokens
are refreshed automatically when a refresh token is available.

Preferences, local watched IDs, and completed download records survive restarts.
Secrets are held in platform secure storage. Short-lived TorBox CDN links are
requested only when a download starts and are not saved in app state.

## Build and test

Flutter 3.47.2 and Dart 3.13.2 were used for the supplied builds.

```powershell
.\tool\test.ps1
.\tool\build_android.ps1
.\tool\build_windows.ps1
```

To run the Android end-to-end journey on a booted emulator or phone:

```powershell
.\tool\test.ps1 -AndroidDevice emulator-5554
```

The helper prepares directory junctions for Flutter's Windows plugins. This is
needed on Windows hosts where Developer Mode (and therefore ordinary symlink
creation) is disabled; it does not change that security setting.

More detail is in [architecture](docs/architecture.md), [security](docs/security.md),
[test report](docs/test-report.md), [Windows computer-use replay](docs/computer-use-replay.md),
and [product plan](docs/product-plan.md).

## Known v1 boundaries

- The live catalog and Trakt mapping are movie-first. Series episode browsing
  and episode-level scrobbling are the next functional slice.
- Android's system download continues if the app process is killed, but v1 does
  not yet reattach an in-progress job after a cold restart. A job completed
  while the app remains open is persisted normally.
- AIOStreams descriptions vary by provider. Unknown fields receive conservative
  scores instead of being guessed; cache state is verified directly when an
  info hash is available.
- A personal Trakt client ID and secret are required because this repository
  does not ship shared application credentials.
