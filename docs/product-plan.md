# Product plan

## Validated v1 scope

The original stack remains intact: TorBox is the media backend, Trakt owns
cross-device history, AIOStreams aggregates candidate sources, and Stremio can
remain on the Shield. TorBridge adds the missing offline-first path on Windows
and Android without modifying the Shield setup.

Delivered in v1:

- shared Android/Windows Flutter application;
- Stremio-like responsive Discover, Downloads, Library, and Settings surfaces;
- Cinemeta movie search and configured AIOStreams stream lookup;
- automatic cache verification and explainable best-link ranking;
- TorBox torrent/file resolution and short-lived link generation;
- system-managed Android downloads and Windows Downloads-folder storage;
- embedded online/offline playback;
- local watched state plus Trakt device authorization, scrobbling, history, and
  access-token refresh;
- secure credentials and persistent preferences/completed-download records;
- unit, contract, responsive-widget, emulator, build, and runtime visual checks.

## Delivered in v1.1

- series metadata, season and episode navigation, artwork, canonical episode
  stream IDs, and episode-aware fallback scrobbling;
- a loopback-only Stremio addon and range server with exact-item deep links;
- Android foreground serving and Download Manager restart reconciliation;
- source/audio/subtitle tags, manual version replacement, retry/cancel/delete;
- configurable delayed removal after watched-state synchronization from Trakt;
- an in-app diagnostics screen for the complete handoff.

## Next slice

1. Add optional ongoing encrypted synchronization between paired devices,
   including preference revisions and device-owned download summaries.
2. Add per-profile rules so a partner can have independent languages, quality,
   Trakt authorization, and watched state on the same installation.
3. Replace the Android development signing key with a private release key and
   add update metadata before wider distribution.
4. Add opt-in automatic next-episode queues with Wi-Fi, charging, and free-space
   rules.

## Delivered in v1.2

- a five-minute, one-time desktop setup QR with no credentials embedded;
- AES-256-GCM authenticated transfer over the local network;
- Android QR scanning, matching verification code, import preview, and explicit
  replacement confirmation;
- transfer of TorBox, AIOStreams, Trakt, and download preferences while keeping
  media files, file paths, downloads, and watched records device-local.

## Later options

- Background completion notifications can offer **Play now** and **Mark
  watched** actions.
- A secure LAN mode can expose Windows downloads to a Stremio device such as a
  Shield; it needs pairing and HTTPS rather than reusing the loopback bridge.

Forking Stremio should only be reconsidered if native integration becomes a
core product requirement and the long-term cost of tracking its desktop,
Android, and player internals is accepted.
