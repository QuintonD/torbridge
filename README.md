# TorBridge

TorBridge is an Android and Windows companion for a TorBox + AIOStreams +
Stremio + Trakt setup. Search for a movie or exact series episode, let the app
rank the available files, download the best match, then play the local file in
Stremio so Stremio remains the owner of playback and Trakt scrobbling.

The current v1.2 build is usable without credentials in demo mode. Live mode
uses your configured AIOStreams manifest and TorBox account; Trakt is optional.

## Installable builds

- `dist/TorBridge-Android-1.2.9-arm64.apk` — smaller Android APK for ARM64 phones,
  including Pixel 7a and Galaxy S25. Install over the existing app.
- `dist/TorBridge-Android-1.2.9.apk` — sideloadable Android APK (Android 7+
  by Flutter's current minimum; tested on API 30, 34, and 36).
- `dist/TorBridge-Windows-x64-1.2.7.zip` — extract the complete archive and run
  `torbridge.exe`. Do not move the executable away from its adjacent DLL and
  `data` files.

The Android artifact is an optimized release build signed with a development
key. It is appropriate for personal sideloading, not Play Store distribution.

The 1.2.7 UI update adds visible player choices, download status filters,
responsive headers, and clearer search controls. See the [UI pass](docs/ui-pass/README.md)
for rendered previews and the imagegen design reference. Install the Android APK
over the existing app to retain app data; do not uninstall first.

Android 1.2.9 moves completed downloads into TorBridge's own library so Android
Download Manager cleanup cannot remove the retained video. Open the updated app
once on each device to migrate existing readable downloads. Unavailable files
remain under **Downloads → Needs attention**, with **Retry download**. See the
[retention fix](docs/android-download-retention.md) and earlier
[download recovery notes](docs/android-download-recovery.md).

Build the smaller APK with `./tool/build_android.ps1 -Arm64`. Both Android
artifacts use the same signing key and version code, so switching between
universal and ARM64 builds does not prevent future updates. Updating the app
does not re-download its saved videos.

## First run

1. Open **Settings → Connect services**.
2. Paste the configured AIOStreams manifest URL you already use with Stremio.
   TorBridge accepts `stremio://` and HTTPS manifest URLs and preserves the
   configuration path.
3. Paste your TorBox API token and choose **Check & save**. Both endpoints are
   validated before live mode is enabled.
4. Optional: create a personal Trakt API application, enter its client ID and
   secret, save, then choose **Authorize Trakt** and approve the one-time code.
5. Choose **Copy addon URL and open Stremio**, then confirm installation of
   **TorBridge Offline**. TorBridge opens the direct Stremio manifest link and
   also copies `http://127.0.0.1:11471/manifest.json` as a manual fallback.
6. Set preferred audio, subtitles, quality, size limit, HDR, whether the
   preferred audio is mandatory, and an optional watched-file cleanup delay.

Search for a movie or series, choose a season and episode, inspect the
explanation under **Recommended download**, and choose **Download best match**.
On Windows files go to `Downloads\TorBridge`. Android uses the system Download
Manager with app-specific Movies storage so the foreground Stremio bridge can
serve the file reliably without broad storage permission.

Only download or play media you are authorized to access.

## Transfer desktop setup to Android

1. Keep the Windows computer and Android device on the same local network.
2. In TorBridge Desktop, open **Settings → Transfer setup → Show setup QR**.
3. In TorBridge Mobile, open **Settings → Transfer setup → Scan desktop QR**.
4. Confirm that the six-digit codes match, review the services being imported,
   and choose **Import setup**.

On the first transfer, Windows Firewall may ask for network access. Allow
TorBridge on **Private networks** only; public-network access is unnecessary.

The QR contains a short-lived LAN address, one-time authorization token, and
random encryption key—not the TorBox, AIOStreams, or Trakt credentials. The
desktop sends an AES-256-GCM authenticated ciphertext, accepts one claim, and
ends the pairing session after five minutes. Preferences and credentials are
transferred; downloads, watched history, and local file paths stay on their
original device.

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

## Playback, Stremio, and history

Completed files can be played in TorBridge, Stremio, or another installed player
from the download action menu. TorBridge's main player has audio-language and
embedded-subtitle selection, automatic/off choices, auto-hiding title controls,
and fullscreen playback. Android also offers **Use compatibility player** if
the main renderer fails; that fallback has limited track controls.

**Play in Stremio** sends a complete local stream directly to Stremio's player,
avoiding the online detail-page lookup. The loopback addon remains available at
`http://127.0.0.1:11471/manifest.json`. TorBridge must remain running while it
serves the file. A Stremio client may still require connectivity to initialize
its own UI; use TorBridge or an installed external player if that happens.

Direct Stremio playback may not associate the file with library history or
Trakt automatically. TorBridge only sends playback scrobbles for its embedded
player. External playback does not automatically mark the download watched.
Trakt watched-history import and configured cleanup remain available.

See the [playback audit](docs/playback-audit.md) for findings and verification
limits, including Android rendering and offline Stremio device testing.

Preferences, local watched IDs, queued Android jobs, and download records
survive restarts. Android reattaches to its system Download Manager job after a
cold start. Windows reports an interrupted in-process download as retryable.
Secrets are held in platform secure storage. Short-lived TorBox CDN links are
requested only when a download starts and are not saved in app state.

When an addon playback URL fails with a retryable HTTP error, TorBridge first
refreshes it and tries a suitable alternative. It then falls back automatically
to a fresh TorBox CDN link. When the source includes an info-hash, TorBridge
adds or finds that torrent and selects its referenced file. For URL-only
sources, it searches the connected TorBox account for the exact title and
`SxxExx` file. If the torrent is not owned yet, TorBridge searches TorBox by
IMDb ID and episode, adds a suitable cached magnet, waits for its file list,
and selects the exact episode itself. This shared recovery path also applies to
season batch downloads; a season pack is added once and reused for its other
episodes. If no exact file is available, TorBridge reports that instead of
risking the wrong episode.

Download cards preserve quality, codec, HDR/release, audio, subtitle, size, and
source metadata. Use **Find another version** to pick a suitable alternative or
**Change download rules** before replacing a 1080p file with a 4K file. The
Diagnostics tab checks the local addon, file paths, canonical episode IDs, and
service configuration without displaying credentials.

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

## Known boundaries

- The local addon serves Stremio on the same Windows or Android device as
  TorBridge. Serving a Windows download to a Shield over the LAN is not part of
  this release.
- Direct Stremio playback avoids online title lookup but may not associate the
  stream with canonical movie/episode history. Client startup can still depend
  on connectivity; use the embedded or external player when necessary.
- Artwork is fetched from Cinemeta and uses an offline-safe gradient fallback
  when an image is unavailable.
- AIOStreams descriptions vary by provider. Unknown fields receive conservative
  scores instead of being guessed; cache state is verified directly when an
  info hash is available.
- A personal Trakt client ID and secret are required because this repository
  does not ship shared application credentials.
