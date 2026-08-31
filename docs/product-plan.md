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

## Next slice

1. Add series metadata, season/episode navigation, `tt…:season:episode` stream
   IDs, and episode-specific Trakt payloads.
2. Persist the Android Download Manager ID at enqueue time and reconcile active
   and completed jobs during app startup.
3. Add per-profile rules so a partner can have independent languages, quality,
   Trakt authorization, and watched state on the same installation.
4. Add manual alternative download as an escape hatch while retaining the
   recommended one-click default.
5. Replace the Android development signing key with a private release key and
   add update metadata before wider distribution.

## Later options

- Stremio deep links or a small local addon/bridge can expose “send to
  TorBridge” if the upstream clients offer a stable handoff point. This should
  remain an adapter, not a hard dependency.
- Background completion notifications can offer **Play now** and **Mark
  watched** actions.
- A transparent diagnostics view can show raw AIOStreams fields and the score
  calculation without exposing tokens.

Forking Stremio should only be reconsidered if native integration becomes a
core product requirement and the long-term cost of tracking its desktop,
Android, and player internals is accepted.

