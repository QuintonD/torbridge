# Application audit — 10 September 2026

The audit below records failures reproduced in **1.2.10**, source
[`640efa7`](https://github.com/QuintonD/torbridge/commit/640efa7).
**All ten issue groups and the additional inspection findings are addressed in
[1.2.11](https://github.com/QuintonD/torbridge/releases/tag/v1.2.11).** The original
1.2.10 binaries remain unchanged.

## Resolution in 1.2.11

- A01: initial and recovery TorBox series downloads verify numeric episode
  identity in the filename, including when a source supplies an incorrect index.
- A02: Windows transfers atomically reserve separate attempt directories;
  concurrent same-name tests verify distinct paths and intact response bytes.
- A03: preferences, downloads, watched IDs, and history load independently.
  Unreadable sections are backed up; unreadable download lists cannot be replaced,
  and malformed individual records remain in subsequent saves.
- A04: cancel/delete resolve the current job and wait for an in-flight enqueue
  before retiring its native ID. Failed removal retains the record.
- A05/A06: completion updates local history before Trakt requests. Title and
  episode metadata survive file removal and restart; imported Trakt history and
  legacy ID-only entries are visible in Library. Explicit local watched/unwatched
  choices take precedence over remote snapshots.
- A07: superseded and cleared searches cannot publish late results; catalog
  requests have timeouts.
- A08/A09/A10: negative cache labels take precedence, binary units use binary
  multipliers, and HDR10+ retains its format.
- Additional findings: watched changes target the supplied movie/episode and use
  the correct add/remove endpoint in order; device authorization polls do not
  overlap and increase the delay on slowdown; Trakt requests have timeouts.
  Diagnostics use explicit severity, player separators are corrected, and Windows
  build/update scripts derive versions and copy the complete bundle with backup.
  Native command exit codes determine packaging success.
- Follow-up finding: watched sync now follows short Trakt pages until completion
  instead of assuming the requested page size was honored. This matches
  [Trakt's pagination guidance](https://github.com/trakt/trakt-api/discussions/775).

The release notes record final validation and device-testing limits.

## Results

**Eleven targeted desired-behavior assertions failed**, reproducing ten issue
groups below. Additional concerns are identified separately by code inspection.
The existing release suite passed 56 host tests and three native API 36 tests;
these new probes expose gaps in that coverage.

Priority means repair order: **P1** for wrong media or possible file/record loss;
**P2** for broken workflows; **P3** for presentation and metadata inaccuracies.

| ID | Priority | Reproduced behavior | User impact |
| --- | --- | --- | --- |
| A01 | P1 | Asking a season pack for S01E02 with an invalid file index returned S01E01. A separate probe matched S01E01 to a filename containing S01E010. | A download can carry the selected episode's label but contain different media. |
| A02 | P1 | Two concurrent Windows downloads with the same suggested filename returned the same destination path. | Transfers can overwrite or corrupt each other's file. |
| A03 | P1 | Malformed saved preferences prevented valid download records from loading; starting a new download then overwrote the saved records without the old entry. | Existing videos can lose their app records. The probe did not delete video bytes. |
| A04 | P2 | Cancelling from an older card snapshot passed a null platform ID even though the current job had acquired a native download ID. | The card disappears while the Android transfer can continue in the background. |
| A05 | P2 | A 100% playback stop without a connected Trakt session left the local watched set empty. | Finishing a video does not add it to local history or make it eligible for watched cleanup. |
| A06 | P2 | A non-demo watched title without a local download rendered the Library's empty-state message. | Remote history and manually watched titles disappear from the visible Library when no download record supplies their metadata. |
| A07 | P2 | A slow response for an older search replaced the results of a newer search. | Search results can disagree with the query currently shown. |
| A08 | P2 | A source labeled `Not cached` parsed as `CacheStatus.cached`. | The cached-only rule can accept a source that explicitly says it is not cached. |
| A09 | P2 | `10 GiB` parsed as 10,000,000,000 bytes instead of 10,737,418,240. | A download can pass a hard size limit while actually exceeding it. |
| A10 | P3 | `HDR10+` parsed as plain HDR10. | Quality labels and source scoring lose the distinction. |

## Evidence and proposed repairs

### A01 — Episode identity must be verified against the file

[`episodeFile`](https://github.com/QuintonD/torbridge/blob/640efa7/lib/integrations/torbox_client.dart#L51)
returns `preferredFile(index)` immediately when an index is supplied. An invalid
index falls back to the largest video. Name matching also uses substring tests
without a trailing numeric boundary. The initial torrent-only download path
uses `preferredFile` without passing the requested episode at all.

Repair: use requested season/episode metadata for every series path; validate
the indexed file is a video for that episode; fail explicitly when identity
cannot be established. Match complete numeric episode tokens, not prefixes.

### A02 — Windows destinations are checked but not reserved

[`DioDownloadService.download`](https://github.com/QuintonD/torbridge/blob/640efa7/lib/services/download_service.dart#L279)
chooses a name before Dio asynchronously creates the file. Another transfer can
choose that same nonexistent path. The probe used a temporary directory and a
mock HTTP adapter, with no real downloads or user files.

Repair: give each attempt its own directory, or reserve the destination
atomically before starting network I/O. Verify the resulting bytes as well as
the path when adding the regression test.

### A03 — Recover independent parts of saved state independently

[`SharedPreferencesLocalStateStore.read`](https://github.com/QuintonD/torbridge/blob/640efa7/lib/services/local_state_store.dart#L39)
parses preferences before downloads. One malformed value aborts the entire read.
[`initialize`](https://github.com/QuintonD/torbridge/blob/640efa7/lib/app/app_state.dart#L327)
continues with empty in-memory downloads, and later saves replace the existing
serialized download list. The reproduction used mocked SharedPreferences only.

Repair: read and validate each state section independently, preserve an original
backup on parse failure, and prevent destructive replacement of an unread list.

### A04 — Resolve the latest job before cancelling or deleting

[`cancelDownload`](https://github.com/QuintonD/torbridge/blob/640efa7/lib/app/app_state.dart#L1069)
and `deleteDownload` trust the `DownloadJob` object passed by the UI. That object
can predate native enqueue or a recovery attempt. The probe acquired the new ID
before invoking cancellation, so the enqueue callback's existing late-cancel
guard could not help.

Repair: resolve the current job by ID at action time, track cancellation across
all attempts, and retire any native job created during that operation.

### A05 / A06 — Local history is tied to remote sync and local files

[`scrobble`](https://github.com/QuintonD/torbridge/blob/640efa7/lib/app/app_state.dart#L498)
returns before updating local watched state if Trakt is disconnected, and a
failed remote request also bypasses that update. Both player entry points omit
the optional completion callback. Separately,
[`LibraryScreen`](https://github.com/QuintonD/torbridge/blob/640efa7/lib/features/library/library_screen.dart#L17)
only renders watched download records and the built-in demo titles.

Repair: record completion locally first, sync it separately, and persist title
metadata for watched history independently of downloaded files.

### A07 — Ignore superseded searches

[`searchCatalog`](https://github.com/QuintonD/torbridge/blob/640efa7/lib/app/app_state.dart#L441)
unconditionally writes each completed request to state. Repair with a request
generation or cancellation token, including when clearing a search. Cinemeta
also lacks configured network timeouts.

### A08 / A09 / A10 — Parse metadata conservatively

[`_cacheStatus`](https://github.com/QuintonD/torbridge/blob/640efa7/lib/domain/stream_parser.dart#L131)
recognizes the substring `cached` before handling negation. The cache confirmation
step only checks unknown sources, so it does not correct that false positive.
[`_sizeBytes`](https://github.com/QuintonD/torbridge/blob/640efa7/lib/domain/stream_parser.dart#L189)
uses decimal multipliers for binary units.
[`_hdr`](https://github.com/QuintonD/torbridge/blob/640efa7/lib/domain/stream_parser.dart#L125)
puts a word boundary after `+`, which fails for a normal terminal `HDR10+` label.

Repair: prioritize explicit negative cache wording, use binary multipliers for
GiB/MiB, and match HDR10+ with an appropriate terminator. Add fixtures for both
positive and negative examples so fixes do not simply invert the errors.

## Additional findings from code inspection

- **P2 — Mark unwatched leaves Trakt history unchanged.**
  [`toggleWatched`](https://github.com/QuintonD/torbridge/blob/640efa7/lib/app/app_state.dart#L482)
  only invokes `_markSelectedWatched()` when adding a watched ID; removing an ID
  never calls the history-remove endpoint. The add helper also uses the current
  Discover selection rather than the passed ID. Use an explicit target plus add/remove
  action. No live Trakt account was changed to test this.
- **P2 — Trakt authorization can overlap requests and ignores backoff.**
  [`Timer.periodic`](https://github.com/QuintonD/torbridge/blob/640efa7/lib/features/settings/settings_screen.dart#L1069)
  starts another poll without an in-flight guard. The `slowDown` branch changes
  text but not the interval. Trakt's Dio clients have no configured timeouts.
  Serialize polls, increase the interval on slowdown, and bound requests.
- **P2 — Windows build/update scripts are stale.**
  [`build_windows.ps1`](https://github.com/QuintonD/torbridge/blob/640efa7/tool/build_windows.ps1#L20)
  always names the archive 1.2.0.
  [`update_local_windows.ps1`](https://github.com/QuintonD/torbridge/blob/640efa7/tool/update_local_windows.ps1)
  hardcodes a 1.0.0 folder and 1.2.0+3 marker, and copies only the executable,
  Flutter DLL, and data instead of all plugin DLLs. Derive versions from the
  build and update the complete application bundle.
- **P2 — Android's packaging helper can stop on a warning.** During 1.2.10
  packaging, Windows PowerShell treated Flutter's Kotlin plugin warning on
  stderr as terminating because the helper sets `ErrorActionPreference=Stop`.
  Running Flutter directly with exit-code checks produced verified APKs. Native
  command exit status should determine build success.
- **P3 — Diagnostics and player text are inconsistent.** The connected Trakt
  check still says Stremio owns scrobbling, while the handoff explanation correctly
  warns direct playback may not sync history. Some unavailable service checks
  still receive green icons because the UI infers severity from a few text
  substrings. Audio/subtitle labels contain literal ` ? ` separators. Use typed
  diagnostic results and review these strings together.

## Reproduce the audit

```powershell
.\tool\audit_app.ps1
```

The runner now executes the `AUDIT` regression cases in
[`test/app_state_test.dart`](../test/app_state_test.dart). The original eleven
probes are part of the normal passing release suite, alongside additional race,
metadata persistence, parser, and Trakt tests. Historical probe definitions remain
in [`tool/audit/2026-09-10-probes.dart.txt`](../tool/audit/2026-09-10-probes.dart.txt);
on the original audit commit `8c8fc6b`, the historical runner reproduced eleven
failed assertions. Fixtures use mocked state and network responses and disposable
files; no personal credentials or real media library are used.

Run all checks with `tool/test.ps1`, and packaging fixtures with
`tool/test_release_tools.ps1`.

## Scope and next steps

Reviewed download lifecycle, native retention and deletion, source parsing and
selection, local persistence, watched/Trakt flows, player wiring, discovery and
Library state, setup transfer, loopback streaming, and release tooling. The
existing transfer and streaming tests were considered; this was not a penetration
test or exhaustive codec/device compatibility review. No physical Pixel was
available, and no live account was used for these probes.

The findings above are repaired in 1.2.11. Device/provider-specific networking
and codec compatibility remain bounded by the release validation; this report
is not a claim that every possible application defect has been eliminated.
