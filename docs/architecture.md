# Architecture

## Decision

TorBridge is a focused Flutter companion rather than a Stremio fork. One Dart
UI and domain layer serves Android and Windows, while downloads use the native
behavior appropriate to each platform.

This boundary is deliberate. The Stremio addon protocol exposes resources such
as `/stream/{type}/{id}.json`, and a stream response supplies a direct URL,
info hash, or external URL. It does not provide an addon callback for the full
offline-download lifecycle. A companion can consume the same configured addon
manifest while owning ranking, durable downloads, offline playback, and Trakt
events without carrying the maintenance cost of a full Stremio fork. See the
[Stremio addon protocol](https://github.com/Stremio/stremio-addon-sdk/blob/master/docs/protocol.md).

## Data flow

```text
Cinemeta search
      │
      ▼
movie IMDb ID ──► configured AIOStreams stream resource
                         │
                         ▼
                 parsed source candidates
                         │
          unknown hashes│ one batched check
                         ▼
                 TorBox cache status
                         │
                         ▼
             deterministic rule engine
              │ winner + reasons
              ▼
     direct URL or TorBox requestdl URL
              │
       ┌──────┴────────┐
       ▼               ▼
Android Download    Windows file
Manager             download
       └──────┬────────┘
              ▼
       local MPV playback ──► Trakt scrobble/history
```

## Modules

- `lib/domain`: candidate model, metadata parser, explainable ranking engine.
- `lib/integrations`: Cinemeta, AIOStreams, TorBox, and Trakt HTTP contracts.
- `lib/services`: secure credentials, local state, and platform downloads.
- `lib/features`: responsive Discover, Downloads, Library, Settings, and Player
  screens.
- `android/.../MainActivity.kt`: narrow Download Manager method channel.
- `vendor/flutter_secure_storage_windows`: upstream Windows secure-storage
  implementation with ATL-only UTF conversion replaced by Win32 conversion so
  the standard Visual Studio desktop workload is sufficient.

## Ranking contract

Hard rules execute before preference scoring. A source is ineligible when it is
outside the quality range, exceeds the size cap, matches a blocked release tag,
is not confirmed cached while instant-only mode is on, or lacks required audio.

Eligible sources receive weighted scores for cache status, distance from the
preferred resolution, audio/subtitle language order, codec order, HDR, release
quality, and relative size. Stable tie-breakers are cache status, smaller size,
then source ID. The same inputs therefore produce the same result on every
device.

When AIOStreams leaves an info-hash source's cache status unknown, TorBridge
uses TorBox's `checkcached` endpoint once for the whole set before ranking. At
download time it finds or adds the torrent, selects the requested file index
when present (otherwise the largest video), and calls `requestdl`. The TorBox
service contracts are documented in the
[official TorBox SDK](https://github.com/TorBox-App/torbox-sdk-js/blob/main/documentation/services/TorrentsService.md).

## State

SharedPreferences stores non-secret preferences, local watched IDs, and
completed download metadata. The platform credential store contains the
AIOStreams manifest URL, TorBox token, Trakt app credentials, and Trakt tokens.
Ephemeral CDN URLs do not enter persisted app state.

The UI uses Riverpod for a single observable application state. Demo mode is an
offline-safe fixture that exercises the complete ranking/download/player UI and
is also used by deterministic end-to-end tests.

