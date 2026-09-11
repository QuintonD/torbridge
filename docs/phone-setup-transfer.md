# Phone-to-phone setup transfer

## Design and review

The existing transfer service uses Dart TCP sockets and AES-256-GCM, with a
random key and single-use claim token in a five-minute QR offer. It has no
Windows dependency. The Android UI was the restriction: it only exposed the
scanner. Enable the sender on Android while retaining Windows export and the
existing protocol, private IPv4 address validation, and explicit import preview.

The sender keeps its settings. Import replaces the receiving device's
connections and download preferences. Downloads, local watched history and
files are outside the bundle. No reset, cleanup or download-engine change is
needed. A configured Trakt session is included, as in desktop transfer.

Keep the sending QR screen open and both phones unlocked on the same Wi-Fi.
The existing address selector prioritizes Wi-Fi interfaces; it does not select
Tailscale's 100.64.0.0/10 addresses. A VPN or guest-network client isolation can
still prevent communication. Do not promise connectivity merely from a shared
SSID. Transfer requires local IPv4 connectivity, not the desktop or an internet
service. The QR itself grants access to credentials and must remain private.

## Failure cases and validation

- Preserve encrypted round-trip, matching verification codes, one-time claim,
  and tampered-key rejection. Test expiration, closure and replacement offers.
- Regression testing found that an old successful client's asynchronous cleanup
  could cancel a replacement offer. Guard request processing and cleanup with
  the offer generation so an old socket cannot affect a newer session.
- Make sender and receiver dialogs scrollable on phones. Test Android export
  and import action visibility, Windows export, QR display and close behavior
  at 360 x 640 with 1.4x text scaling. Fix the existing settings dropdown's
  horizontal overflow exposed by this test.
- Exercise Android's actual address discovery, server binding and encrypted
  redemption on an API 36 emulator, using synthetic credentials only. This is
  a same-device socket test, not camera scanning between two physical phones.
- Run host tests and analysis, build signed Android and complete Windows
  artifacts, check signatures/metadata/ABIs, and verify uploaded checksums.

Physical S25-to-Pixel camera scanning, Android 17 permission behavior and the
user's Wi-Fi/VPN configuration remain device-testing limitations. If the local
connection fails, show actionable instructions and create a new QR after a used
or expired attempt. Do not change network settings or user data automatically.

## Using it

Install 1.2.15 over TorBridge on both phones. On the configured S25, choose
**Settings > Transfer setup > Show setup QR**. On the Pixel, choose
**Settings > Transfer setup > Scan setup QR**, grant camera permission, compare
the six-digit codes, then choose **Import setup**. The source configuration is
unchanged. Run Diagnostics on the Pixel after importing.
