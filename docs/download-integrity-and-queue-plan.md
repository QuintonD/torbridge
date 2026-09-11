# Download integrity and queue resilience: validated implementation plan

Date: 2026-09-11. Baseline: 1.2.13, main commit `3ad87ad`.

## What the pre-implementation audit established

No production behavior was changed to obtain these results. Synthetic files and
local HTTP fixtures were used; the physical Pixel and its filesystem are not
available for inspection.

| Finding | Evidence | Consequence |
| --- | --- | --- |
| Readability is not integrity | A host probe accepts both HTML and a one-byte `.mp4`; an API 36 native probe downloads and retains an HTTP 200 HTML error page as a video. | A green file check currently overstates what was tested. |
| A batch is not durable during discovery | A host probe returns the first episode's source, fails DNS on the second, and observes zero saved jobs and `busy == true`. | Interrupted discovery can lose the selected work before downloads begin. |
| Refresh can reuse an expired source | A fake-clock host probe waits four hours, times out source refresh, and observes the original URL used again. | Refresh-on-start needs an explicit freshness policy and a safe fallback. |
| Native resume works when the server cooperates | API 36: interrupt after 1,024 of 4,096 bytes with a stable ETag; Android retries the same native ID with `Range: bytes=1024-` and the validator, then produces the exact original bytes. | Do not replace ordinary paused transfers or reset their progress. |
| Storage diagnostics only visit known completed/unavailable records | Code review of `checkDownloadedFiles`, `LocalDownloadAccess`, and the retention journal. | Untracked transfers, stale journal entries, empty attempt directories, and unknown files are not inventoried. |
| Native and Flutter records can be saved at different times | Native enqueue stores a path, then Flutter asynchronously stores the native ID. | Startup reconciliation must account for the enqueue/save interruption window. |
| Integrity evidence is lost after retention | Retained status reports current file length as both downloaded and total. | A later truncated file can look self-consistent without an independent completion-size record. |
| Queue advancement depends on the Flutter process | `_pumpDownloadQueue` is driven by controller futures; the native receiver retains files but does not prepare the next source. | Saving a large queue alone does not make it finish unattended after process death. |

The three host probes and two API 36 native probes passed. These tests assert
the observed baseline behavior; they are evidence of defects or working behavior,
not claims that the proposed fixes already pass. The native resume test took
about 79 seconds, including Android's retry delay. It is an interrupted HTTP
transfer test, not a physical weak-Wi-Fi or multi-gigabyte endurance test.

TorBox currently documents a three-hour link window. Its API documentation also
distinguishes starting a request from continuing an established transfer and
contains inconsistent one-/three-hour wording. Therefore correctness must not
depend on a guessed hard-coded expiry time. Request a link immediately before
use, handle rejection, and do not cancel a progressing transfer solely because
of age. Sources: [TorBox help](https://support.torbox.app/en/articles/15315517-why-are-my-download-links-not-working),
[TorBox API](https://www.postman.com/torbox/torbox-api/documentation/b6l9hbv/main-api?entity=request-29572726-fbb2cd77-7dbf-4e73-913c-8544f7acedd0),
[Android DownloadManager](https://developer.android.com/reference/android/app/DownloadManager).

## Patch order and required behavior

### 1. Make storage diagnostics an honest, non-destructive audit

- Inventory TorBridge-owned transfer and library roots, native download records,
  retention mappings, and saved jobs. Treat recorded legacy/public locations as
  individual read-only targets; do not recursively scan unrelated phone storage.
- Reconcile references before calling anything orphaned. Separate active partial
  files, tracked failures, retained completed files, empty attempt directories,
  untracked files, missing targets, duplicate references, and unreadable records.
- Report counts and bytes for each category, with affected records and next
  actions. An untracked file is a finding requiring investigation, not permission
  to delete it. Diagnostics must not cancel transfers, delete files, or rewrite
  damaged records. Existing safe retention remains a separate recovery operation.
- Run inventory work off Android's UI thread. Bound scans, avoid following
  symlinks outside managed roots, and report a partial/changed scan as unverified.
  Recheck state when files change during a scan.
- Check zero length, obvious HTML/JSON error payloads, recognized media signatures,
  and exact byte counts where independent evidence exists. Keep estimated addon
  sizes separate from authoritative TorBox file sizes and HTTP transfer totals.
- Preserve completion byte counts independently of the current file length.
  Recognized headers plus equal size are structural checks, not whole-video proof.
  Unsupported formats and legacy files without reliable size evidence must say
  unverified rather than corrupt or healthy.
- Do not mark a new known-invalid payload ready for playback. Preserve its bytes
  and record for diagnosis. Protect completed bytes from system cleanup even when
  deeper integrity cannot be established.
- A future optional full-file hash can detect later changes against a baseline;
  creating a hash now cannot prove the file was originally correct. Full decode
  or a trusted provider checksum offers stronger evidence but is not implied by
  a quick scan. No universal “all files are certainly valid” badge.

### 2. Persist queue intent before discovery and prepare links at execution time

- Persist every selected episode's identity and intended selection before any
  network lookup. Source preparation is a durable per-job state. A later failure
  keeps earlier and not-yet-resolved work, and every exit clears transient busy UI.
- Skip duplicate pending/waiting intents, maintain stable ordering, and preserve
  cancellation while a source lookup or enqueue is outstanding.
- Generate direct TorBox URLs only when a transfer can start. Persist stable
  torrent/file identity and integrity metadata, never signed links or API tokens
  in queue records. A queued addon URL whose refresh failed must not silently
  fall back to an old in-memory URL; use a freshly prepared stable source or wait.
- Bound preparation and recovery attempts. Cancellation and persistence failure
  prevent a late preparation result from starting an untracked transfer.
- Add native job/attempt identity to the journal and reconcile native records
  before restoring queued jobs. Test the gap between native enqueue and Flutter
  saving its ID; do not guess that an unfamiliar active native job is disposable.
- Check storage again at transfer start, reporting exact versus estimated queue
  demand and retained partial bytes. Metadata cannot reserve space against other
  applications; do not advertise a guaranteed capacity budget.
- Separate background queue advancement from the Flutter screen/controller.
  Prototype a durable coordinator that performs short, constrained link-preparation
  jobs and hands transfers to DownloadManager. Reconcile on completion and restart,
  using a single queue owner to prevent a foreground/background double enqueue.
  Validate secure credential access and cancellation before enabling unattended
  advancement. Until that gate passes, state the existing requirement to reopen
  the app; persistence alone is not an unattended-download guarantee.

### 3. Recover from network instability without retry storms or lost progress

- Keep DownloadManager in charge of its running and paused transfers. Preserve
  the native ID, byte count, and partial file while Android retries a network
  interruption. Surface the wait reason, last-progress time, and retry context.
- Resume app-side preparation after a stable usable network and successful
  bounded service checks, with shared exponential backoff and jitter. A queue of
  100 items must not produce 100 simultaneous connectivity probes.
- Persist retry eligibility/time, cap retries, and retain manual resume/cancel.
  Authentication, storage, invalid-file, and permanent source errors require
  their own treatment. Respect rate-limit cooldowns; do not cycle sources rapidly
  in response to 429. Never switch the user's network policy silently.
- Treat weak signal as context, not proof of internet availability. Prefer
  observed progress, connectivity changes, and service reachability over Wi-Fi
  bars or bandwidth estimates. No new location permission solely to read RSSI.
- If a reconnect meets an expired-link rejection, prepare a fresh URL after
  confirming source identity. Never concatenate bytes from a different release.
  Preserve the old attempt until replacement preparation succeeds.
- Existing DownloadManager recovery starts a new transfer when its old request
  cannot resume. Its public API does not offer URL replacement on an existing
  request. Byte-preserving resume across replacement URLs would require a
  separate, app-owned range downloader with durable offsets and validator checks;
  do not claim that this patch supplies that capability. Do not use a token-bearing
  “permalink” as a shortcut without auditing redirects, native URL persistence,
  and credential exposure. See [DownloadManager.Request](https://developer.android.com/reference/android/app/DownloadManager.Request).

A background replacement must respect Android's execution limits. A long-running
`dataSync` foreground service is not an unlimited workaround: Android 15 adds a
six-hour-per-24-hour limit under the documented conditions, and Android 16 can
charge long-running WorkManager workers against job quota. Evaluate short workers
for preparation and system-managed transfer execution; consider user-initiated
data-transfer jobs for a future custom downloader on supported API levels.
Sources: [foreground-service timeouts](https://developer.android.com/develop/background-work/services/fgs/timeout),
[long-running workers](https://developer.android.com/develop/background-work/background-tasks/persistent/how-to/long-running),
[user-initiated transfers](https://developer.android.com/develop/background-work/background-tasks/uidt).

## Validation gates before merging or releasing

| Area | Required failure cases and assertions |
| --- | --- |
| Inventory | Tracked complete, active partial, failed partial, orphan, missing file, stale journal, duplicate reference, empty directory, malformed record, outside-root path, symlink, and mutation during scan. Snapshot leaves every fixture byte and record unchanged. |
| Integrity | Empty file; HTTP 200 HTML/JSON; recognizable but truncated media; valid small media; exact-size mismatch; unknown/estimated length; unsupported container; retained-file truncation after completion. No false claim of full verification. |
| Durable queue | Discovery fails on item 2 of 100; process exits before discovery; exits after native enqueue but before Dart ID save; completion while Flutter is absent; reboot; competing foreground/background owners; duplicate submission; cancel during lookup; failed persistent write. No lost or duplicate transfer intent. |
| Fresh links | Fake clock advances beyond the provider window; every job gets a fresh execution-time link; timed-out refresh cannot reuse stale URL; 401/403/410 refresh is bounded; 429 cooldown; source identity cannot drift during resumed content. |
| Unstable network | Stable ETag/206 resume retains the same bytes and ID; missing/changed validator; server ignores Range; repeated offline/online changes; prolonged pause then expired URL; app restart and cancellation during backoff. |
| Scale | 100–1,000 fixture intents, bounded active transfers/probes, storage estimate includes waiting work, no UI-blocking full-file scans, no hot retry loop, unknown scan results remain visible. |
| Delivery | Clean Flutter analysis and relevant host tests; native download/storage suite on an available emulator with API level reported; signed in-place upgrade retaining fixtures; APK metadata/ABIs; complete Windows ZIP when shared code changes; published asset checksums. |

Each patch must add desired-behavior regression tests before changing that
behavior, replacing the baseline probes that deliberately demonstrate defects.
No network-engine rewrite should be merged merely because a local fixture passes.
Physical Pixel/S25 comparisons, weak-signal endurance, and authenticated multi-GB
TorBox downloads remain explicit device validation work.


## Implementation review and delivery scope (1.2.14)

The implementation uses bounded header reads and recorded transfer lengths,
not a full decode pass or a hash supplied by the provider. Unknown formats,
content URIs that cannot be inspected, legacy files without a size baseline,
and incomplete scans remain explicitly unverified. The read-only inventory
preserves orphan files, failed partials, retention journals and unreadable records.
It does not offer an automatic cleanup operation.

The queue now persists every episode intent before discovery. A regression with
1,000 intents fails discovery on the second item: one transfer starts, 999 wait,
and all 1,000 records remain saved. Timed-out refresh cannot reuse the old URL.
A shared persisted retry schedule backs off from roughly one minute to eight
minutes, with jitter and a five-failure automatic limit. Manual resume resets the
network-attempt budget. HTTP 429 has a minimum five-minute default when Android
cannot expose Retry-After; API responses preserve the supplied seconds or date.
The timer uses the later network/rate-limit deadline and is cancelled on disposal.
Native pending/paused transfers continue under DownloadManager ownership.

Native destinations now include an opaque job ID. Startup can reconcile an
otherwise saved intent whose native enqueue completed before Flutter saved its
ID. Multiple matches or unowned active records stop uncertain new work and
remain visible for review. This does not retroactively infer a reliable identity
for every legacy transfer.

### Background and transfer-engine gates

The architecture review did not approve adding a second background writer:
LocalStateStore currently replaces a whole SharedPreferences record list, the
controller owns cancellation and active slots, and source preparation depends
on Flutter plugins and secure credential access. A headless callback without a
transactional ownership protocol could overwrite newer foreground state or
start duplicates. No headless worker or custom range engine ships in this patch.
The native completion receiver still retains files without Flutter polling;
queued preparation and automatic application retries require TorBridge open.
This is a deliberate gate outcome, not a claim of unattended queue completion.

Cross-URL partial continuation is likewise not implemented. Android cannot
replace a URL in an existing public DownloadManager request. A terminal resume
failure uses a newly prepared transfer; it never appends bytes from an alternative
source to the old file. Stable-validator, ignored-Range, and changed-validator
fixtures validate that boundary. Physical process-kill/reboot endurance, weak RF,
Wi-Fi roaming, battery restrictions, and authenticated multi-GB TorBox queues
are not represented by these local fixtures and remain device validation work.

### Review corrections

Review caught URI/plain-path double counting, a potential rapid retry timer when
DNS and 429 deadlines overlap, premature repeated queue snapshot writes, and
integrity exceptions being obscured by source-recovery wrappers. Regression tests
cover the corrected behavior. No changes to credentials, user files or signing
identity are part of recovery.
