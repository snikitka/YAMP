import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:yamp/app.dart';
import 'package:yamp/core/fake_core.dart';
import 'package:yamp/player/engine.dart';
import 'package:yamp/state/controller.dart';
import 'package:yamp/ui/main_page.dart';
import 'package:yamp/ui/player/compact_player.dart';

class _Recording extends FakeCore {
  final sent = <Map<String, Object?>>[];

  List<Map<String, Object?>> get presence => sent.where((c) => c['cmd'] == 'presence').toList();

  @override
  void send(Map<String, Object?> c) {
    sent.add(c);
    super.send(c);
  }
}

Future<(_Recording, Controller, SilentEngine)> _open(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1280, 860);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final core = _Recording();
  final engine = SilentEngine();
  final c = Controller(core, engine: engine);
  await tester.pumpWidget(YmdApp(controller: c));
  await tester.pumpAndSettle();
  final manual = find.text('Вставить токен вручную');
  if (manual.evaluate().isNotEmpty) {
    await tester.tap(manual);
    await tester.pumpAndSettle();
  }
  await tester.enterText(find.byType(TextField), 'good-token');
  await tester.pump();
  await tester.tap(find.text('Войти'));
  await tester.pump(const Duration(milliseconds: 600));
  await tester.pumpAndSettle();
  return (core, c, engine);
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('Discord: трек, перемотка и пауза уходят в ядро', (tester) async {
    final (core, c, engine) = await _open(tester);
    await tester.tap(find.text('Моя волна'));
    await _settle(tester);
    engine.progress(const Duration(milliseconds: 500));
    await tester.pump();

    final t = c.player.track!;
    final started = core.presence.last;
    expect(started['playing'], isTrue);
    expect(started['title'], t.title);
    expect(started['artist'], isNotEmpty);
    expect(started['link'], t.link);

    final before = core.presence.length;
    engine.progress(const Duration(seconds: 1));
    await tester.pump();
    expect(core.presence.length, before, reason: 'обычное воспроизведение не шлёт статус');

    c.player.seek(const Duration(seconds: 60));
    await tester.pump();
    expect(core.presence.length, before + 1);
    expect(core.presence.last['position'], greaterThanOrEqualTo(59));

    c.player.pause();
    await tester.pump();
    expect(core.presence.last['playing'], isFalse);

    c.setDiscord(false);
    expect(core.sent.last, {'cmd': 'prefs', 'discord': false});
    expect(c.discord, isFalse);
  });

  testWidgets('мини-плеер: управление, закрепление и возврат в полный вид', (tester) async {
    final (_, c, engine) = await _open(tester);
    await tester.tap(find.text('Моя волна'));
    await _settle(tester);
    engine.progress(const Duration(milliseconds: 500));
    await tester.pump();

    await tester.tap(find.byTooltip('Мини-плеер').first);
    await tester.pump();
    expect(c.compact.value, isTrue);
    for (final w in [Controller.compactSize.width, 320.0, 480.0]) {
      tester.view.physicalSize = Size(w, Controller.compactSize.height);
      await tester.pump();
      expect(tester.takeException(), isNull, reason: 'ширина $w');
    }
    tester.view.physicalSize = Controller.compactSize;
    await tester.pump();

    final mini = find.byType(CompactPlayer);
    expect(find.descendant(of: mini, matching: find.text(c.player.track!.title)), findsOneWidget);

    final playing = c.player.playing;
    await tester.tap(find.descendant(of: mini, matching: find.byTooltip(playing ? 'Пауза' : 'Играть')));
    await tester.pump();
    expect(c.player.playing, !playing);

    await tester.tap(find.byTooltip('Поверх всех окон'));
    await tester.pump();
    expect(c.pinned.value, isTrue);
    expect(find.byTooltip('Открепить от верха'), findsOneWidget);

    await tester.tap(find.byTooltip('Развернуть окно'));
    tester.view.physicalSize = const Size(1280, 860);
    await _settle(tester);
    expect(c.compact.value, isFalse);
    expect(c.pinned.value, isFalse);
    expect(find.byType(CompactPlayer), findsNothing);
    expect(find.byType(MainPage), findsOneWidget);
  });
}
