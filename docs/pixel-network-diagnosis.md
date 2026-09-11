# Pixel network recovery investigation — 1.2.13

## Evidence and diagnosis review

The reported failure has two stages: Android cannot resume an interrupted
transfer (1008), then TorBox link preparation fails to resolve `api.torbox.app`.
The DNS failure is explicit evidence of the second failure; it does not explain
why the original transfer was interrupted. Choosing a different media source
can still encounter the same TorBox API dependency.

Both phones used the same Wi-Fi. The working phone had Tailscale connected
without an exit node; the failing phone had no custom Private DNS. This narrows
the comparison but does not isolate a cause. Tailscale can affect DNS without
an exit node, depending on its DNS configuration. A device resolver problem,
network filtering, or intermittent DNS failure remains possible. A provider-wide
outage is less likely given the successful comparison, but the requests were
not captured simultaneously. No Tailscale setting was inspected or changed.
See [Tailscale DNS behavior](https://tailscale.com/docs/reference/dns-in-tailscale).

The later storage check reported ample free destination space. That weakens a
current capacity explanation, but does not disprove earlier storage exhaustion.
Android's temporary-system storage category has not been attributed to TorBridge.
An Android 17 regression, expired URL, and server range/ETag incompatibility are
unproven explanations for the original interrupted transfers.

HTTP 400 is also ambiguous: Android DownloadManager can generate it locally
when cleartext HTTP is blocked. A native fixture reproduces that case with zero
requests arriving at the server, separately from a real server 400 fixture.
The app therefore labels it as rejection by Android or the server. See the
[Android DownloadThread implementation](https://android.googlesource.com/platform/packages/providers/DownloadProvider/+/refs/tags/android-16.0.0_r4/src/com/android/providers/downloads/DownloadThread.java).

## Confirmed application gaps and patch plan

| Gap | Implemented treatment |
| --- | --- |
| Diagnostics only reported configured credentials | Resolve the configured service hostname using the system resolver, then perform a bounded HTTPS manifest or token check; report DNS, authorization, TLS, timeout, and HTTP failures separately. |
| Error text combined a TorBox failure with an unrelated source hostname | Use typed errors with the failing request host and stage. Omit request paths, query strings, response bodies, and raw Dio exception dumps. Sanitize saved legacy DNS errors. |
| DNS failure consumed ordinary source recovery and left a failed batch | Persist a waiting-for-network state, pause pending work, and offer explicit Resume waiting downloads. Do not repeatedly retry an unresolved network. |
| Native jobs were removed before replacement-link preparation succeeded | Keep the existing native ID and file until a replacement URL and storage preflight succeed; retain the record if cancellation fails. |
| Empty offline library received a green storage-protection result | Report that there are no completed files to verify. |
| Little evidence to compare the two phones | Show Android API level, active network presence, Android validation, VPN presence, Private DNS mode, and check time. No DNS server addresses or private configuration URLs are displayed. |

Review also identified and fixed queue races: an immediate resume waits for the
previous operation to exit; restored native failures join an already paused
queue; removing a waiting record lets eligible queued work proceed. Existing
native transfers can continue while pending transfers are paused. Cancellation
and deletion remain explicit actions; an update never clears the library.

These changes do not bypass system DNS, change VPN settings, pin service IPs,
disable TLS checks, or permit additional cleartext hosts. Android network
validation describes the active network, not guaranteed access to a particular
provider. See [Android network state](https://developer.android.com/develop/connectivity/network-ops/reading-network-state)
and [system hostname lookup](https://api.dart.dev/dart-io/InternetAddress/lookup.html).

## Device treatment and remaining work

Install the update over the existing app and run Diagnostics on both phones
close together. Compare TorBox DNS, TorBox API, configured addon DNS/manifest,
and Android network results. A passing check only describes that moment and
does not validate the media CDN or a multi-gigabyte transfer.

If only the Pixel fails DNS, compare it on cellular or a different Wi-Fi.
Briefly disconnecting Tailscale on the working phone and repeating the same
checks would help determine whether its DNS configuration accounts for the
difference. These comparisons change one variable at a time; they have not yet
been performed. Do not reset the phone or clear application data for this test.

After service checks pass, use Downloads → Resume waiting downloads. New Android
transfers remain serial. Reopen TorBridge if Android closes it before the next
queued item starts. A fresh transfer may be needed when Android cannot resume
the old one; preserving its record does not make unusable partial bytes resumable.

## Validation scope

Host regressions exercise DNS failure during fallback, safe saved-error migration,
explicit resume, queue races, cancellation failure, and real service-check
classification using synthetic fixtures. Native tests exercise the Android
network channel and system DNS, local-policy and server HTTP 400, interrupted
response 1008 recovery, storage preflight, retained files, byte ranges, and
background completion. Exact results and artifact verification are recorded in
the versioned release notes.

An API 36 emulator is available. No physical Pixel 7a, Galaxy S25, Android 17
device, or authenticated provider download was tested. The application fixes
are reproducible; the phone's underlying network fault remains unresolved.
