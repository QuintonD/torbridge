# Pixel download failures: investigation and 1.2.12 changes

The report after 1.2.11 shows HTTP 400, Android cannot-resume errors, system
retry waits, and insufficient storage during a large re-download batch. Android
Settings shows 93 GB used out of 128 GB and 27 GB of temporary system files.
These screenshots establish the reported failures, but do not establish why
the provider returned 400, what interrupted the connections, or which component
owns the temporary files. They do not justify deleting the app or its library.

## Confirmed implementation gaps

- HTTP 400 was excluded from source recovery. A regression fixture reproduced
  the failure before the fix: only the original URL was attempted.
- Restored Download Manager jobs bypassed source recovery. Startup also began
  monitoring before loading credentials, which recovery now needs.
- Bulk requests and manual retries had no application concurrency limit or
  free-space preflight. Many multi-gigabyte transfers could start together.
- After a retryable source failure, a later storage failure could incorrectly
  continue through more source attempts and retire the failed native record.

## Changes

- Android starts one new transfer at a time. Waiting records remain saved and
  cancellable. Sources are refreshed when a waiting transfer gets its turn.
- On upgrade, existing Android transfers are adopted without discarding their
  partial files. They occupy queue slots until they finish. If they fail, their
  recovery attempts join the queue instead of starting another concurrent batch.
- HTTP 400 participates in the existing finite recovery sequence: refreshed
  source, supported host migration, suitable alternative, then a fresh TorBox
  link when configured. Persistent rejection still ends in a visible failure.
- Reopened transfers use that same recovery sequence after credentials load.
  Storage and other non-retryable failures stop recovery immediately and retain
  the current record and native ID. Link preparation has bounded timeouts.
- Before each new transfer, Android's actual destination filesystem is checked
  with `StatFs.availableBytes`. The advertised size plus 512 MiB of headroom must
  fit. Unknown sizes still require the headroom. This is an estimate, not a disk
  reservation: inaccurate metadata or other apps can still exhaust storage.
- Diagnostics shows available download storage and the estimated queued size.
  HTTP failures report the attempted request hostname without returning signed
  URLs or query parameters from the native bridge. Direct TorBox requests do not
  inherit addon-specific request headers.

## Background behavior and limits

Android continues an already enqueued transfer when the Flutter process closes,
and the native completion receiver retains completed files. Starting the next
queued item and performing source recovery require TorBridge to be running.
Reopen the app if Android closes it; queued items resume from saved records.
The queue message explicitly explains this limitation. Existing paused native
transfers keep Android's network/Wi-Fi/retry status rather than being deleted.

No physical Pixel 7a, Android 17 environment, authenticated provider download,
or multi-gigabyte capacity stress test was available. The 27 GB temporary-system
category is not attributed to TorBridge. This update does not clear data, reclaim
that category, restore deleted bytes, or guarantee that a provider will serve a
particular source. A full rewrite is not supported by the evidence collected.

## Validation

- 88 host tests pass, including HTTP 400 recovery and bounded persistent failure,
  credential-dependent restored recovery, serialized old-job retries, saved
  queue cancellation, storage rechecks, and stopping on native storage errors.
- Four native integration tests pass on an Android API 36 emulator. Local HTTP
  fixtures exercise real Download Manager HTTP 400 and truncated-response 1008,
  hostname reporting, free-space checks, retry/delete/re-download, retained file
  recovery, file/content ranges, and native background completion retention.
- Flutter analysis is clean. Release artifact validation is recorded in the
  [1.2.12 release notes](releases/v1.2.12.md).

References: [DownloadManager error codes](https://developer.android.com/reference/android/app/DownloadManager)
and [StatFs available bytes](https://developer.android.com/reference/android/os/StatFs#getAvailableBytes()).
