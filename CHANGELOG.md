# Changelog

Installable files are available in [GitHub Releases](https://github.com/QuintonD/torbridge/releases).
Android and Windows can have different current versions.

## Android and Windows 1.2.14 - 2026-09-11

- Persist complete episode batches before discovery; refresh links at execution
  and stop stale URL reuse after refresh timeouts.
- Back off network recovery with a persisted schedule and five-attempt automatic
  limit; honor rate-limit cooldowns and preserve native paused transfers.
- Reconcile native enqueue/save gaps and stop ambiguous ownership from starting
  another transfer.
- Add non-destructive file/native/journal inventory and transfer progress details.
  Reject obvious error payloads and detect recorded-size mismatches, including
  retained files truncated after completion. Unknown integrity stays unverified.
- Bound Windows transfer concurrency to two.

Application queue advancement still requires TorBridge open. A failed native
resume can require a fresh transfer from zero. No automatic cleanup or reset.
[Plan and review](docs/download-integrity-and-queue-plan.md) -
[Release notes](docs/releases/v1.2.14.md).


## Android and Windows 1.2.13 - 2026-09-11

- Pause pending downloads after DNS, connection, or link-preparation timeout
  failures. Persist waiting records and resume explicitly with fresh links.
- Keep failed Android native jobs until a replacement URL and storage check
  succeed; preserve the record when retirement fails.
- Check actual service DNS, TorBox token acceptance, and addon manifest access
  in Diagnostics. Show Android network, VPN, Private DNS mode, and check time.
- Replace raw connection exceptions with safe request-host and stage messages;
  migrate saved DNS errors without clearing settings or downloaded files.
- Correct the ambiguous Android HTTP 400 label and unverified empty-library
  storage-protection result. Fix immediate-resume and restored-queue races.

Validation: 101 host tests, six native API 36 tests, clean analysis, signed APK
metadata/ABI verification, and an in-place emulator upgrade preserving app data.
[Diagnosis and patch review](docs/pixel-network-diagnosis.md) -
[Release notes](docs/releases/v1.2.13.md).
Physical Pixel 7a / Android 17 and live provider transfers remain unverified.

## Android and Windows 1.2.12 - 2026-09-10

- Include HTTP 400 and restored Android transfers in bounded source recovery.
- Queue new Android transfers and old-job recovery attempts one at a time;
  persist waiting jobs and refresh their sources when they start.
- Check estimated size against free download storage with 512 MiB of headroom.
  Show available space in Diagnostics and stop recovery on storage errors.
- Preserve failed storage records and native IDs; report request hostnames
  without exposing signed URLs. Bound recovery link preparation.
- An active Android transfer can continue outside the app; reopen TorBridge to
  start the next queued item if Android closes the process.

Validation: 88 host tests, four native API 36 tests, and clean analysis. Physical
Pixel 7a / Android 17 and live provider behavior remain unverified.
[Investigation](docs/android-download-batches.md) - [Release notes](docs/releases/v1.2.12.md).

## Android and Windows 1.2.11 - 2026-09-10

- Fix every reproduced issue and additional finding from the September audit:
  exact season-pack selection, concurrent Windows filenames, saved-state recovery,
  cancellation races, local watched history, search ordering, and source metadata.
- Preserve history metadata independently of files and record completion even
  without Trakt or when its request fails. Correct explicit mark-unwatched sync.
- Serialize Trakt authorization polling, honor slowdown, and load all watched
  pages even when Trakt returns fewer entries than requested.
- Use explicit diagnostic severity and correct audio/subtitle separators.
- Package current Windows versions and update all plugin files with an installation
  backup. Judge native packaging commands by their exit code.
- Retain the Android interrupted-download recovery and storage protection fixes
  from 1.2.10, with the same app ID and signing certificate for in-place updates.

[Audit and resolution](docs/application-audit-2026-09-10.md) -
[Release details](docs/releases/v1.2.11.md).

## Android 1.2.10 — 2026-09-10

- Correct the misleading "file already exists" message for Android's interrupted
  download error and enable source refresh/TorBox recovery for that failure.
- Retire previous Android jobs before manual retry; bound source lookup and link
  preparation, and respect cancellation during preparation.
- Explain Android network, Wi-Fi, and retry waits on download cards.
- Keep records when deletion fails and follow journaled file moves on deletion.
- Correct older saved error messages while preserving actual destination conflicts.

Validation: 56 host tests, three native API 36 integration tests, clean analysis,
and verified update signatures. [Investigation and limits](docs/android-download-retry.md).

## Android 1.2.9 — 2026-09-09

- Retain completed videos outside Download Manager's original cleanup path.
- Migrate readable older downloads and protect native background completions.
- Isolate transfer destinations and guard against duplicate retry taps.
- Provide a smaller ARM64 APK alongside the universal APK.

The original release incorrectly described Android error 1008 as a destination
conflict. Version 1.2.10 corrects that diagnosis and handling.
[Retention details](docs/android-download-retention.md).

## Android 1.2.8 — 2026-09-09

- Recover readable Android files through saved paths and platform download IDs.
- Keep unavailable records under Needs attention with a retry action.
- Support local file and content URI playback with streaming byte ranges.

[Recovery details](docs/android-download-recovery.md).

## Android and Windows 1.2.7 — 2026-09-05

- Add clear playback choices, download filters, responsive headers and search.
- Improve local playback handoff and surface download diagnostics.

[UI changes and screenshots](docs/ui-pass/README.md).
