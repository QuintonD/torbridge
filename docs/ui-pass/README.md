# UI/UX pass — 1.2.7

## Implemented

- Responsive shared page headers: action buttons move below the title on narrow screens.
- Downloads: one scrolling surface, status filters with a resettable empty state, and explicit Play, Stremio, and External player actions. Playback status precedes file metadata. Technical tags no longer compete with playback buttons as chips.
- Discover: visible search submission, clear action, keyboard Search action, and keyboard dismissal on submission.
- Shared styling: consistent card borders and corners, stronger page headings, and minimum 48-pixel outlined/text button height.
- Library: clearer empty-state guidance that can scroll when text is enlarged.
- Diagnostics: corrected the claim that direct Stremio playback always owns Trakt attribution.
- Narrow-screen navigation: oversized labels yield to icons with existing tooltips and semantics when text scaling is high.

Existing downloads, credentials, storage paths, and preferences are unchanged. Version increases to 1.2.7+10 for an in-place update.

## Visual direction

The imagegen skill's built-in image generation tool produced `downloads-concept.png`. This is a design reference, not a screenshot or bundled app asset. The exact prompt is in `concept-prompt.txt`. The implementation keeps the existing palette and native Flutter controls; it does not reproduce every illustrative detail of the concept.

`downloads-360.png`, `downloads-430.png`, and `downloads-1280.png` are Flutter widget-render captures using real fonts. The smallest capture uses 140% text scaling and is scrolled to expose playback actions. Poster fallback graphics are intentional: test fixtures do not fetch online artwork.

## Verification

Static analysis is clean and all 39 host tests pass. The release APK verifies successfully, retains package ID `app.torbridge.torbridge`, and increments the version code to 10. Its signing certificate matches the previous 1.2.6 playback APK, supporting an in-place update without uninstalling.

Android and Windows release builds both passed. Deliverables are `dist/TorBridge-Android-1.2.7.apk` and `dist/TorBridge-Windows-x64-1.2.7.zip`.

Responsive tests exercise download filters, empty-filter recovery, and visible playback choices at 360×640, 430×900, and 1280×900. The 360-pixel case also checks larger text. Existing discovery, download, library, preference, and diagnostic journeys remain in the host suite.

To regenerate captures, set `TORBRIDGE_UI_CAPTURE=1` and `TORBRIDGE_FONT_DIR` to the Flutter SDK's `bin/cache/artifacts/material_fonts`, then run the widget tests named `downloads filters and actions fit`.

Widget captures validate layout, not native Android playback, installer behavior, or external-player handoff. Those device-level checks remain separate from this UI pass.
