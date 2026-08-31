# Test report

Run date: 2026-08-31

## Passed

| Area | Coverage | Result |
| --- | --- | --- |
| Static analysis | Flutter analyzer over app, tests, integration tests, and platform bindings | Pass, no issues |
| Recommendation | hard filters, weighted ranking, reasons, deterministic ordering, and preference-driven reranking | Pass |
| Source parsing | quality, codec, HDR, languages, size, cache, and release tags | Pass |
| HTTP contracts | AIOStreams configured resource path, TorBox file/link and batched cache lookup, and Trakt scrobble envelope | Pass with mocked endpoints |
| Local persistence | preferences, watched IDs, and completed download records | Pass |
| Desktop UI | wide Discover -> ranked recommendation -> download -> watched -> player -> Settings journey | Pass |
| Phone UI | compact navigation, language controls, quality controls, and reranking | Pass |
| Android E2E | mark watched, real system download, Ready offline, ExoPlayer initialization, error-free player surface, reranking, and reset | Pass on the API 36 Android Studio emulator |
| Android visual replay | real app download, Ready offline, offline playback, rendered video frame, Dutch/4K reranking, and reset | Pass through Computer Use |
| Windows visual replay | final packaged x64 build launch and Settings mutation; full download/player journey on the immediately preceding package | Pass through Computer Use |
| Release builds | optimized universal Android APK and self-contained Windows x64 ZIP | Pass |

The host suite contains 11 passing tests. The expanded Android integration test
uses a small CC0 MP4 and the real Android Download Manager; it does not mock the
download or player boundary. Earlier compatibility runs also passed on API 30
and API 34 emulators; the final ExoPlayer regression replay was run on API 36.

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
| `TorBridge-Android-1.0.0.apk` | 101,440,942 bytes | `3FC8C1EB4D028C5449B1D85F84E5916279E1EBC0B214CB37072EF05BB1B8C598` |
| `TorBridge-Windows-x64-1.0.0.zip` | 33,723,078 bytes | `89E3C746936E143A07B90C1E82D55EFFF87EDFC045C224EC6B1A03BB860734FA` |
