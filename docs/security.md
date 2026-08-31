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

## Network boundary

AIOStreams accepts HTTPS, plus HTTP only for localhost development. TorBox,
Trakt, and Cinemeta use fixed HTTPS origins. TorBox's documented `requestdl`
endpoint requires the token as a query parameter; the resulting CDN URL is held
only long enough to hand it to the downloader and is not persisted by
TorBridge. The operating-system download service may retain request details as
part of its own download record.

Trakt uses the device authorization flow, so the user approves a one-time code
in a browser rather than entering a Trakt password in TorBridge. See Trakt's
[authorization reference](https://docs.trakt.tv/reference/authentication-devices).

## Local files

Windows creates unique names under `Downloads\TorBridge`. Android delegates to
Download Manager, preferring public Downloads and falling back to app-specific
external Movies storage where necessary. Filenames are stripped of Windows and
path-separator metacharacters before use.

## Distribution

The supplied APK uses Flutter's development signing key. It is intended for
personal sideloading. Before public distribution, generate and protect a
dedicated signing key, configure release signing outside version control, and
publish verifiable hashes through a trusted update channel.

This project intentionally ignores keystores, certificates, databases,
environment files, generated builds, and local secrets.

