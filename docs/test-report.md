# Test report

Run date: 2026-08-31

## Passed

| Area | Coverage | Result |
| --- | --- | --- |
| Static analysis | Flutter analyzer over app, tests, integration tests, and platform bindings | Pass, no issues |
| Recommendation | hard filters, weighted ranking, reasons, deterministic ordering, and preference-driven reranking | Pass |
| Source parsing | quality, codec, HDR, languages, size, cache, and release tags | Pass |
| HTTP contracts | Cinemeta episode metadata, AIOStreams canonical episode paths, TorBox file/cache lookup, Trakt movie/episode scrobbles, and paginated watched sync | Pass with mocked endpoints |
| Local Stremio addon | manifest, exact `tt…:season:episode` matching, stream metadata, binge group, and partial byte-range response | Pass against a real loopback server |
| Local persistence | preferences including cleanup delay, exact watched IDs, v1-compatible download records, and queued Android job fields | Pass |
| Cleanup | completed watched download removed at the configured zero-day boundary | Pass with deletion spy |
| QR setup transfer | QR excludes credentials, AES-256-GCM bundle round-trip, tamper rejection, one-time claim, preference/credential import, and device-local download exclusion | Pass against a real loopback socket |
| Desktop UI | artwork/fallbacks, source/audio/subtitle tags, download actions, five-destination navigation, Settings, and Diagnostics | Pass in widget suite and release-build visual replay |
| Phone UI | compact navigation, language/quality/cleanup controls, reranking, and Diagnostics | Pass |
| Android platform compile | Download Manager reconciliation, foreground loopback server, camera permission, and ML Kit QR scanner | Pass in release APK build |
| Windows visual replay | v1.2 release build: Transfer setup card, generated QR, verification code, service summary, expiry guidance, and existing connection state | Pass through Computer Use |
| Release builds | optimized universal Android APK and self-contained Windows x64 ZIP | Pass |

The host suite contains 20 passing tests. The checked-in Android integration
test uses a small CC0 MP4 and the real Android Download Manager; it does not
mock the download or player boundary. Its previously validated playback route
now selects **Play in TorBridge** from the fallback menu. Earlier compatibility
runs passed on API 30, API 34, and API 36; the v1.1 turn compiled both debug and
release Android variants but did not have an emulator attached for a new E2E
run.

The v1.1 Windows visual pass found and corrected one misleading diagnostic
severity: “no missing paths detected” originally matched the word “missing” and
showed an error icon. The final predicate only marks an actual nonzero missing
file count as a failure.

## Improvement-loop findings

### Windows accessibility-tree crash

Computer Use reproduced a Windows process exit immediately after changing a
Settings dropdown. Debug output ended in Flutter's Windows accessibility bridge
with `Failed to update ui::AXTree`. The affected dropdowns were replaced with
stable `SegmentedButton` and `ChoiceChip` controls, tooltip churn was reduced,
and Windows receives a stable single semantics root. The same Settings mutation
was replayed repeatedly and in the final ZIP without a crash.

The Windows-only semantics guard is a pragmatic runtime workaround for the
upstream Flutter accessibility-tree failure. Android keeps its complete
semantics tree; Windows screen-reader granularity is temporarily reduced until
the upstream issue can be removed safely.

### Android black playback surface

Computer Use found that both a downloaded `content://` URI and a direct stream
opened a black media-kit surface on the Android emulator. The Android player was
moved to Flutter's official `video_player` plugin, backed by ExoPlayer, while the
Windows media-kit path remains unchanged. The new player has explicit loading,
ready, and error states and preserves Trakt start/pause/stop scrobbling. The
expanded integration test now requires `video-playback-ready` and rejects a
`playback-error`; the visual replay also captured an advancing movie frame.

### Clean-build recovery

The Windows plugin-junction preparation script previously failed on the first
`flutter pub get` after a clean checkout when Developer Mode symlinks were not
available. It now uses the generated plugin metadata to create junctions and
retries dependency resolution once. This path was exercised by the clean Android
rebuild that produced the final APK.

### Repeatable integration state

The Android test now normalizes persisted watched state before asserting the
watched transition, so rerunning it against an existing emulator is deterministic.
A test-entry APK is also no longer used for standalone visual replay; a normal
application APK is rebuilt and installed first.

## Live-account boundary

HTTP shapes were checked against official service documentation and covered by
contract tests. No TorBox, AIOStreams, or Trakt token was copied into source code
or fixtures. A live-account smoke test therefore remains a first-run check for
the account owner; the Connections dialog validates credentials before saving
them to the operating-system credential vault.

## Release checksums

| Artifact | Size | SHA-256 |
| --- | ---: | --- |
| `TorBridge-Android-1.2.0.apk` | 119,150,629 bytes | `E62B2E4AE39C5C4B67A72E6A71D05CE10B4B8356D206EA2FBE008F75D945B44A` |
| `TorBridge-Windows-x64-1.2.0.zip` | 33,990,760 bytes | `6C7F0822382E9452C756A9B6FD482AA0892D3ECAF70DF93A61DD6D5311FEC988` |
