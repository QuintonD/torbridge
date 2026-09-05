# Security notes

## Credentials

- The AIOStreams manifest URL, TorBox API token, Trakt client secret, and OAuth
  tokens use `flutter_secure_storage`.
- Android uses its platform-backed secure-storage implementation. Windows uses
  AES-GCM storage protected by a key held through Windows Credential Manager.
- Secret fields are obscured by default. The app does not print them or add the
  TorBox token to its own logs.
- Connection values are validated before live mode is enabled.

The configured AIOStreams URL may itself contain private configuration data, so
it is treated as a secret even though it is a URL. Do not share screenshots of
the revealed Connections form.

## QR setup transfer

- The QR contains no service credential or preference value. It carries only a
  private LAN endpoint, protocol version, high-entropy one-time token, and
  random session key.
- The desktop encrypts the setup bundle with AES-256-GCM. The authorization
  token is authenticated as associated data, so modified ciphertext, key, or
  session context is rejected.
- A transfer can be claimed once and expires after five minutes. Closing the QR
  dialog immediately stops the listener and discards its in-memory key and
  bundle references.
- The receiving device previews the included services and a matching six-digit
  verification code before replacing its existing setup.
- Downloads, watched IDs, local paths, and Stremio bridge records are excluded.
- Windows may request an inbound firewall exception on first use. Only the
  Private networks scope is needed; public-network access should remain off.

Anyone able to photograph the live QR during its short validity window can act
as the intended receiver, so the QR should be displayed only in a trusted room.
The encryption protects the LAN transport; the visual QR remains the pairing
trust channel.

## Network boundary

AIOStreams accepts HTTPS, plus HTTP only for localhost development. TorBox,
Trakt, and Cinemeta use fixed HTTPS origins. TorBox's documented `requestdl`
endpoint requires the token as a query parameter; the resulting CDN URL is held
only long enough to hand it to the downloader and is not persisted by
TorBridge. The operating-system download service may retain request details as
part of its own download record.

The Stremio addon and media server bind only to IPv4 loopback at
`127.0.0.1:11471`; they are not reachable from the LAN. Media URLs contain a
registered download ID, never a filesystem path, and unknown IDs return 404.
The manifest and stream metadata contain no service credentials.

Trakt uses the device authorization flow, so the user approves a one-time code
in a browser rather than entering a Trakt password in TorBridge. See Trakt's
[authorization reference](https://docs.trakt.tv/reference/authentication-devices).

## Local files

Windows creates unique names under `Downloads\TorBridge`. Android delegates to
Download Manager using app-specific external Movies storage. This lets the
foreground loopback service read completed files without broad storage access.
Filenames are stripped of Windows and path-separator metacharacters before use.

## Distribution

The supplied APK uses Flutter's development signing key. It is intended for
personal sideloading. Before public distribution, generate and protect a
dedicated signing key, configure release signing outside version control, and
publish verifiable hashes through a trusted update channel.

This project intentionally ignores keystores, certificates, databases,
environment files, generated builds, and local secrets.
