# Playback audit — 2026-09-05

## Findings and changes

| Finding | Change |
| --- | --- |
| Android's `video_player` UI did not expose embedded subtitles. Windows had no explicit track menus. | The main player uses media-kit with audio and subtitle menus, including Automatic and Off. Labels use actual container track metadata. Missing tracks are reported instead of inferred from download tags. |
| A permanent AppBar reduced the video area; desktop playback was constrained to 16:9. | The video fills the route with its original aspect ratio. Title/back/actions share the auto-hiding playback overlay. Android requests immersive mode and restores system UI on exit. |
| External player handoff was absent. | Downloads and the player expose an external-player action. Android uses a video ACTION_VIEW chooser, with a narrowly scoped FileProvider for local files. Downloads can use the foreground loopback bridge. Windows opens the system Open With dialog for local files. |
| Stremio handoff navigated to a detail page with `autoPlay=true`, which could require online metadata/addons. | The handoff validates the local file, waits for bridge health, and sends the complete local stream using Stremio's compressed stream player deep link. No online detail request is made by TorBridge. |
| Failed handoffs were not visible on Downloads. | Downloads now displays status/error notices. Launch failures are caught. |
| Invalid range requests could return the entire file or a negative range. Android advertised one byte for an empty file. | Both servers reject invalid/unsatisfiable ranges with HTTP 416 and the file length. Empty responses now have the correct length. The Dart health probe always closes its client. |

## Compatibility and remaining limits

- Earlier testing documented a black media-kit surface on an Android emulator. The existing ExoPlayer implementation remains accessible through **Use compatibility player** in the overlay and error screen. It does not provide embedded subtitle selection. The main Android rendering path needs device verification before treating it as a verified replacement.
- Direct Stremio playback carries the stream and display title, not canonical movie/episode context. Automatic Stremio library history or Trakt attribution is therefore not guaranteed. TorBridge does not send duplicate scrobbles for external playback.
- A Stremio client that requires network access to initialize its own UI can still fail offline. TorBridge's embedded player and installed external players are independent fallback paths. Offline Stremio client behavior has not been verified on-device in this audit.
- Subtitle selection uses tracks embedded in the downloaded file. Download metadata cannot create missing subtitle tracks; fetching online subtitles remains unavailable offline.
- The local HTTP bridge requires TorBridge's process/service to remain alive. No Android device was attached during this audit.
- Windows Open With supports downloaded files. Remote streams can launch VLC from its standard installation locations; otherwise the launch reports failure instead of opening a browser.

## Validation

- Static analysis: no issues. Windows and Android release builds passed. The first Android build hit stale generated integration-test registration; a sequential build with refreshed Flutter metadata resolved it.
- Host suite: 36 tests passed, including a decoded Stremio stream round trip, exact episode mapping, suffix/open-ended ranges, invalid ranges, and empty-file responses.
- Player integration readiness now waits for media-kit's first rendered frame rather than treating construction of the widget as successful playback.
- Android device playback, installed-player chooser behavior, and airplane-mode Stremio launch require device testing; compilation and host tests do not establish these outcomes.

## Protocol references

- [Stremio stream encoding](https://github.com/Stremio/stremio-core/blob/development/src/types/resource/stream.rs): zlib JSON followed by standard base64.
- [Stremio player deep links](https://github.com/Stremio/stremio-core/blob/development/src/deep_links/mod.rs).
- [media-kit track selection](https://pub.dev/documentation/media_kit/latest/).
