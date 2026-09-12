# Pixel download restart investigation — 11 September 2026

## Evidence

The user confirms TorBridge **1.2.15**. A Pixel transfer reached just under 20%
and returned to 0% while the app remained visible. The same selected download
continued on a locked Galaxy S25. The supplied settings show background use
allowed, Unrestricted battery use selected, no denied permissions, and unused-app
management disabled. These screenshots do not establish the current Android
version, network path, HTTP failure, free space, or native download ID.

The earlier [Pixel investigation](pixel-network-diagnosis.md) recorded reason
1008 followed by failure to resolve the TorBox API hostname. It also recorded
same-Wi-Fi use, Tailscale on the working phone and no custom Private DNS on the
failing phone. Those are historical observations, not verified current settings.

### Follow-up Diagnostics result

The user subsequently reports a green TorBox DNS check and this Android network
snapshot: **API 37**, connected, Internet validated by Android, VPN not reported,
and Private DNS inactive. DNS returned addresses (the exact IPv6 count was not
provided). API 37 identifies Android 17. There is no evidence of a DNS failure
at this check, so the earlier DNS failure should not be presented as the current
cause. DNS results do not identify the protocol/address actually used for the
media transfer or test a sustained connection to the media CDN.

In the 1.2.15 source, a validated network produces `DiagnosticSeverity.info`,
rendered as an information icon; warning severity is used when validation is
false. The reported text therefore represents an informational snapshot, not a
detected network fault. The Tailscale sentence is unconditional explanatory
text, not evidence of a VPN on the Pixel.

The next controlled comparison is the same Pixel and selected file on another
trusted Wi-Fi network. Success would point toward the original network path or
its interaction with the Pixel; recurrence would increase the priority of the
download response/resume behavior and Android 17 implementation. Neither outcome
alone proves a root cause, because fresh requests can receive different links.
When available, compare the native job ID and byte counts across a reset.

Google's Android 17 all-app and target-37 behavior-change pages were reviewed;
neither lists a DownloadManager change explaining this symptom. That is not
evidence that Android 17 is bug-free. Current local native validation remains
API 36 only; no API 37 system image is installed in this workspace.

## Confirmed application behavior

Version 1.2.15 uses Android DownloadManager. TorBridge polls its counters once
per second; it does not transfer Android video bytes through Dart. Keeping the
TorBridge screen open does not change the HTTP server's ability to resume.

`_recoverRetryableDownload` treats 1008 (cannot resume) as a source failure. It
can try a refreshed source, a migrated addon URL, an alternative source and a
direct TorBox link. Each `_downloadFromUrl` replacement removes the previous
native job and starts at zero in a new destination. The recovery is bounded,
but it can waste substantial data and its progress callbacks clear the previous
error. This is a confirmed explanation for how a failure becomes an unexplained
progress reset; it is not proof of the cause of this particular Pixel failure.

The native counters are 64-bit and Dart uses integer byte counts. There is no
20% threshold or total-transfer timeout in the Android polling code. Link
preparation timeouts apply before the video transfer. Completed-file retention
and header inspection operate after completion, not at 20%.

## Remaining causes and distinguishing evidence

| Cause | Assessment and useful check |
| --- | --- |
| Connection interrupted; server cannot resume | Leading mechanism to test. AOSP requires an ETag to resume an interrupted response; ignored Range requests or changed content can also prevent continuation. Capture native reason, job ID and bytes. A working S25 connection may simply never have needed a resume. |
| DNS, VPN, filtering, routing or Wi-Fi instability | Current DNS check passes; no VPN or active Private DNS is reported. Previous DNS failure is historical. Intermittent connection/routing problems remain possible; test another trusted network. Same Wi-Fi does not guarantee identical resolver or IPv4/IPv6 paths. |
| Expired/signed link, different CDN endpoint or server error | Same title does not prove identical file, link or CDN response. Compare filename, total bytes and failing host; 401/403/410, 429 and 5xx require different handling. An API check passing does not validate the media CDN. No authenticated source has been probed in this investigation. |
| Storage exhausted or inaccessible | Native reasons 1001/1006/1007 distinguish file/capacity/device errors. Check current destination free bytes against the whole file plus headroom. Metadata estimates can be wrong or other apps can consume space after preflight. Previous ample free space is not a measurement of this attempt. |
| Battery Saver, Data Saver or network policy | Unrestricted app battery use is already selected. Ordinary screen-off Doze is a poor fit for a foreground, screen-on failure. Global savers and metered/roaming policy remain distinct settings; the app permits metered downloads but disallows roaming. Such restrictions can pause transfers; they do not alone establish why bytes were lost. |
| Pixel/Android DownloadManager regression or system interruption | Android 17/API 37 is now confirmed, but a platform regression remains unconfirmed. Exact build and reproduction are still needed. API 36 emulator success does not exclude API 37 behavior, device firmware, Wi-Fi roaming, process/provider failures or thermal problems. |
| Display-only regression | A changed/unknown total can make a percentage fall without losing bytes. Compare byte counters and native ID: a new ID establishes application replacement; the same ID with falling bytes requires platform investigation; the same increasing bytes with a changed total suggests display/metadata effects. |
| Duplicate jobs or an older restored transfer | Existing queue ownership and serialization reduce this risk but do not prove the Pixel has no legacy jobs. Inspect native IDs and saved queue records before changing anything. |
| Permissions, unused-app cleanup or old completed-file cleanup | Not supported by these screenshots or this timing. App-specific Android download storage needs no Photos/Files runtime permission. Camera and nearby-device access do not grant Internet download resumption. Seven-day cleanup is a different issue from a new active transfer restarting. |

The user later tested the Pixel 7a on 4G and reports that the download completed
normally. This strengthens the original Wi-Fi/network-path hypothesis and
weakens a persistent storage-capacity or permission explanation for the resets.
It does not prove the exact interruption cause or that temporary storage is clean.

## Implementation for Android 1.2.16

- A cannot-resume failure stops for manual inspection even if Android reports
  zero bytes. Other terminal native failures after observed progress also stop
  instead of replacing the transfer, including rate-limit responses.
- Android's ordinary queued/paused retries stay attached to the same job. The
  change does not disable successful Range/ETag continuation.
- Preserve the greatest byte count observed during this poll session when the
  final failed snapshot loses counters. Failure messages record the reason,
  reported host and observed bytes. Restored jobs also consider saved bytes.
- Do not cancel the failed native job automatically. Keep its application
  record and any bytes Android leaves behind. Android itself may already have
  removed an unusable partial file; retaining a record cannot restore it.
- Explicit Retry still prepares a new transfer from zero. The message states
  this. Existing zero-progress source refresh and rate-limit backoff remain.
- Diagnostics additionally reports transport, metering, Data Saver status,
  Battery Saver, battery exemption and background restriction. These are
  current app/network snapshots, not a history or a complete account of
  DownloadManager's effective system policy. No signed URLs, credentials or
  private DNS server names are added.

This contains wasteful automatic restarts; it does not repair the Pixel's
unidentified connection fault or implement cross-URL byte continuation. A
resumable engine across refreshed URLs would require durable partial storage,
verified content identity and validators, correct 206/Content-Range handling,
and background ownership. Appending data from an alternative source would risk
corrupting the video.

## Device investigation sequence

1. Leave the successful S25 download alone. On the Pixel, retain the download
   record and note the Android version/build, filename/size, progress bytes,
   native job ID, failure text and approximate failure time.
2. Run Diagnostics on both phones close together. Compare TorBox DNS/API,
   addon checks, Android network and free space. A green result is only a
   point-in-time check. Never share signed links, tokens or raw provider logs.
3. Keep the already selected Unrestricted battery setting. For a controlled
   test, check that global Battery Saver/Extreme Battery Saver and Data Saver
   are off. Do not clear TorBridge or Download Manager storage.
4. Change one variable at a time between attempts: test another trusted Wi-Fi
   network or a hotspot if its data allowance permits. If custom Private DNS
   is configured, compare Automatic temporarily; if a VPN/filter is present,
   compare its effect only if it is not required for privacy or access. Restore
   settings afterward. Avoid interrupting an active download to change networks.
5. If failures persist across networks, compare one manageable file through
   TorBridge and TorBox's own download route. A repeatable failure at the same
   byte offset points toward a different cause than a repeatable elapsed-time
   failure. Browser success is useful but does not prove identical headers or
   resume behavior. Obtain a redacted native reason and HTTP resume trace before
   deciding whether to replace the transfer engine.

Do not uninstall, clear app data, reset networking or factory-reset the phone
as a speculative workaround. Existing downloads and setup should be preserved.

## Validation

- `flutter analyze --no-pub`: no issues.
- `flutter test test --no-pub`: 126 tests passed, including partial native
  failures (1008, 1004, 403, 429, 502), preserving native identity and observed
  progress, explicit retry, restored failures, and lost final byte counters.
- `integration_test/download_recovery_test.dart`: six tests passed on API 36.
  Real truncated responses produce 1008 and disallow automatic replacement;
  explicit replacement remains possible. Network/power fields, real DNS
  failure, HTTP policy, storage preflight and retention checks pass.
- `integration_test/download_integrity_test.dart`: four tests passed on API 36
  in 5m32s. Invalid full responses after interruption do not produce appended
  corrupt files. With a stable ETag and valid range response, the same native
  ID resumes from byte 1024 and yields byte-identical output. Error-page
  rejection and retained-file truncation detection also pass.
- `git diff --check`: passed.

Only the API 36 (Android 16) emulator is connected. No physical Pixel, S25,
Android 17 device or authenticated multi-gigabyte TorBox transfer is available.

## References

- [Android DownloadManager reasons and lifecycle](https://developer.android.com/reference/android/app/DownloadManager)
- [Android 16 DownloadThread implementation](https://android.googlesource.com/platform/packages/providers/DownloadProvider/+/refs/tags/android-16.0.0_r4/src/com/android/providers/downloads/DownloadThread.java)
- [App-specific storage permissions](https://developer.android.com/training/data-storage/app-specific)
- [Doze and App Standby](https://developer.android.com/training/monitoring-device-state/doze-standby)
- [Pixel Data Saver](https://support.google.com/pixelphone/answer/7055392?hl=en)
- [Pixel Battery Saver](https://support.google.com/pixelphone/answer/6187458?hl=en)
- [Pixel network and Private DNS settings](https://support.google.com/pixelphone/answer/2819583?hl=en-GB)
- [Android 17 changes affecting all apps](https://developer.android.com/about/versions/17/behavior-changes-all)
- [Android 17 changes for apps targeting API 37](https://developer.android.com/about/versions/17/behavior-changes-17)
