# TorBridge contributor instructions

## Delivering releases

- Deliver installable builds and updates with **published GitHub release links**
  in `QuintonD/torbridge`. A local `dist/` path is not a delivery link.
- When the user requests an installable update, commit and push its source,
  publish the corresponding versioned GitHub release, upload the verified
  artifacts, and verify the uploaded assets before sharing the links.
- Provide a direct APK download link for the user's device and the release page.
  Prefer the ARM64 APK for Pixel 7a and other supported ARM64 phones; also provide
  a universal APK for other supported Android architectures.
- Do not replace an existing published version with different application bytes.
  Bump both the version name and Android version code for a new update.
- Preserve the application ID and signing certificate so updates can install
  over the existing app. Tell users to install over the app, not uninstall it.
- Include versioned release notes, SHA-256 checksums, validation results, and
  material device-testing limitations. Upload `SHA256SUMS.txt` with the binaries.
- Keep the repository landing page professional and current: prominent download
  links, platform/version labels, concise update steps, screenshots, changelog,
  and a clear route to report problems. Do not advertise an unpublished asset.
- When a fix affects Windows, publish and verify the complete Windows ZIP too;
  Android APKs do not deliver Windows changes. Run `tool/test_release_tools.ps1`
  when changing packaging or update scripts.
- Keep Windows and Android version labels accurate when their releases differ.
  An APK is both the Android installer and update file; do not invent a separate
  patch package or claim automatic updating unless implemented and verified.

## Development and validation

- Read the existing implementation and reproduce reported failures where possible.
  Distinguish confirmed bugs from hypotheses and device behavior not yet tested.
- Run Flutter analysis and relevant tests for code changes. For Android download
  or storage changes, run `integration_test/download_recovery_test.dart` on an
  available Android device or emulator and report its API level.
- Verify release APK signatures, package/version metadata, ABI contents, and
  GitHub asset checksums. A passing emulator test is not a physical Pixel test.
- Never publish credentials, configured addon URLs, personal app state, or logs
  containing tokens. Use fixtures in tests and public screenshots.
- Do not change or clear user data as a workaround for a bug. Preserve download
  records when deletion fails and preserve files during storage recovery.
