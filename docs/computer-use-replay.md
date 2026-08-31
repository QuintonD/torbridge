# Computer-use replay results

Run date: 2026-08-31

The replays used TorBridge demo mode, so Computer Use did not read or enter any
TorBox, AIOStreams, or Trakt credential.

## Windows

The first replay reproduced a real Windows crash after a preference dropdown
changed. Flutter's accessibility bridge reported an invalid AXTree update. After
the Settings controls and Windows semantics boundary were revised, Computer Use
completed the following release journey:

1. Launch the packaged app and verify the wide Discover layout.
2. Mark Big Buck Bunny watched and verify the Watched state.
3. Download the recommended match and verify Ready offline.
4. Open playback and verify the player surface.
5. Change preferred quality to 4K and verify the recommendation drops from the
   preferred match to `1080p available` with a lower score.
6. Restore 1080p and repeat Settings mutations without another process exit.

After the final dependency rebuild, the exact ZIP was unpacked to a new folder,
launched, and exercised again through the 1080p -> 4K -> 1080p Settings path. It
remained responsive.

## Android Studio emulator

The API 36 emulator replay first exposed a black player surface for both offline
and streaming playback. After Android playback moved to the official
ExoPlayer-backed `video_player` path, Computer Use completed this journey:

1. Mark Big Buck Bunny watched.
2. Inspect the 1990-point preferred 1080p/English recommendation.
3. Download the best match and verify Ready offline.
4. Play the downloaded `content://` item and observe a rendered, advancing movie
   frame rather than a black surface.
5. Change audio to Dutch and quality to 4K.
6. Return to Discover and verify the score falls to 1579 with `1080p available`.
7. Restore English audio and 1080p quality.

The automated API 36 integration replay then passed with explicit assertions for
the player-ready key and absence of the playback-error key.

## Pass criteria

These results were observed in the actual Windows release window and Android
Studio emulator. Widget tests and process checks were supporting evidence, not
substitutes for the visual journeys.
