# Changelog

Installable files are available in [GitHub Releases](https://github.com/QuintonD/torbridge/releases).
Android and Windows can have different current versions.

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
