import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:torbridge/app/torbridge_app.dart';
import 'package:torbridge/features/player/player_screen.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Android offline journey', (tester) async {
    MediaKit.ensureInitialized();
    await tester.pumpWidget(const ProviderScope(child: TorBridgeApp()));
    await tester.pumpAndSettle();

    final watchedButton = find.byKey(const Key('toggle-watched'));
    await tester.ensureVisible(watchedButton);
    if (find.text('Watched').evaluate().isNotEmpty) {
      await tester.tap(watchedButton);
      await tester.pump();
    }
    await tester.tap(watchedButton);
    await tester.pump();
    expect(find.text('Watched'), findsOneWidget);

    final downloadButton = find.byKey(const Key('download-best'));
    await tester.ensureVisible(downloadButton);
    await tester.tap(downloadButton);
    await tester.pump();

    final ready = find.text('Ready offline');
    final failed = find.textContaining('Download failed');
    for (
      var attempt = 0;
      attempt < 90 && ready.evaluate().isEmpty && failed.evaluate().isEmpty;
      attempt++
    ) {
      await tester.pump(const Duration(seconds: 1));
    }
    expect(failed, findsNothing);
    expect(ready, findsOneWidget);

    await tester.tap(find.byTooltip('Download actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Play in TorBridge'));
    await tester.pump(const Duration(seconds: 4));
    expect(find.byType(PlayerScreen), findsOneWidget);
    expect(find.byKey(const Key('video-playback-ready')), findsOneWidget);
    expect(find.byKey(const Key('playback-error')), findsNothing);
    await tester.pageBack();
    await tester.pumpAndSettle();

    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('cached-only')), findsOneWidget);
    expect(find.byKey(const Key('preferred-quality')), findsOneWidget);
    expect(find.byKey(const Key('watched-cleanup-delay')), findsOneWidget);

    final dutchAudio = find.byKey(const Key('audio-language-Dutch'));
    await tester.ensureVisible(dutchAudio);
    await tester.tap(dutchAudio);
    await tester.pumpAndSettle();
    expect(tester.widget<ChoiceChip>(dutchAudio).selected, isTrue);

    final ultraHd = find.byKey(const Key('quality-ultraHd2160'));
    await tester.ensureVisible(ultraHd);
    await tester.tap(ultraHd);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Discover'));
    await tester.pumpAndSettle();
    expect(find.text('1080p available'), findsOneWidget);
    expect(find.text('Matches preferred 1080p quality'), findsNothing);

    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    final englishAudio = find.byKey(const Key('audio-language-English'));
    await tester.ensureVisible(englishAudio);
    await tester.tap(englishAudio);
    await tester.pumpAndSettle();
    final fullHd = find.byKey(const Key('quality-fullHd1080'));
    await tester.ensureVisible(fullHd);
    await tester.tap(fullHd);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Diagnostics'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('run-diagnostics')), findsOneWidget);
  });
}
