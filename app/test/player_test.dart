import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:yamp/app.dart';
import 'package:yamp/core/fake_core.dart';
import 'package:yamp/core/fake_player.dart';
import 'package:yamp/player/engine.dart';
import 'package:yamp/state/controller.dart';
import 'package:yamp/state/player.dart';
import 'package:yamp/ui/player/artist_view.dart';
import 'package:yamp/ui/player/controls.dart';
import 'package:yamp/ui/player/history_view.dart';
import 'package:yamp/ui/player/library_view.dart';
import 'package:yamp/ui/player/mini_player.dart';
import 'package:yamp/ui/player/now_playing.dart';
import 'package:yamp/ui/search_view.dart';
import 'package:yamp/ui/widgets.dart';

Future<(FakeCore, Controller, SilentEngine)> _open(WidgetTester tester, {Size size = const Size(1280, 860)}) async {
  tester.view.physicalSize = const Size(1280, 860);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final core = FakeCore();
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
  tester.view.physicalSize = size;
  await tester.pumpAndSettle();
  return (core, c, engine);
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pumpAndSettle();
}

Finder _tip(String message) => find.byTooltip(message);

Finder _link(String text) => find.byWidgetPredicate(
  (w) =>
      w is LinkText &&
      w.onOpen != null &&
      w.parts.any((p) => p.source.isNotEmpty) &&
      w.parts.map((p) => p.text).join() == text,
);

Finder _panel(Finder f) => find.descendant(of: find.byType(NowPlaying), matching: f).first;

Future<void> _tapLink(WidgetTester tester, Finder f) => tester.tapAt(tester.getTopLeft(f) + const Offset(8, 8));

void main() {
  testWidgets('слушать: библиотека, волна, лайк, переходы и конец трека', (tester) async {
    final (core, c, engine) = await _open(tester);

    expect(c.section.value, Section.home);
    expect(find.text('Моя волна'), findsOneWidget);
    expect(find.text('Мне нравится'), findsWidgets);
    expect(find.text('Дорога'), findsOneWidget);
    expect(find.text('2 трека'), findsWidgets);

    await tester.tap(find.text('Моя волна'));
    await _settle(tester);
    final first = c.player.track!;
    expect(core.player.started, isEmpty);
    engine.progress(const Duration(milliseconds: 500));
    expect(c.player.wave, isTrue);
    expect(engine.url, contains('fake://track/${first.id}'));
    expect(engine.isPlaying, isTrue);
    expect(core.player.started, [first.id]);
    expect(_tip('Пауза'), findsOneWidget);
    expect(_tip('Не рекомендовать'), findsOneWidget);
    expect(_tip('Перемешать'), findsNothing);

    await tester.tap(find.descendant(of: find.byType(MiniPlayer), matching: _tip('Мне нравится')));
    await _settle(tester);
    expect(c.player.liked(c.player.track!), isTrue);
    expect(_tip('Убрать из «Мне нравится»'), findsWidgets);

    engine.progress(first.duration);
    await _settle(tester);
    expect(core.player.ended, [first.id]);
    expect(c.player.track!.id, isNot(first.id));

    final second = c.player.track!.id;
    await tester.tap(_tip('Не рекомендовать'));
    await _settle(tester);
    expect(c.player.track!.id, isNot(second));

    await tester.tap(_tip('Пауза'));
    await _settle(tester);
    expect(engine.isPlaying, isFalse);
    expect(find.descendant(of: find.byType(MiniPlayer), matching: _tip('Слушать')), findsOneWidget);

    await core.close();
  });

  testWidgets('плейлист: запуск трека, повтор, качество, панель плеера и Esc', (tester) async {
    final (core, c, engine) = await _open(tester);

    await tester.tap(find.text('Дорога'));
    await _settle(tester);
    expect(find.text('ПЛЕЙЛИСТ'), findsOneWidget);
    expect(find.text('8 треков · 36 мин'), findsOneWidget);
    expect(find.text('Недоступен в каталоге'), findsOneWidget);

    await tester.tap(find.text('Кукушка'));
    await _settle(tester);
    expect(c.player.track!.title, 'Кукушка');
    expect(c.player.source!.id, fakePlaylist);
    expect(find.text('Пауза'), findsOneWidget);

    await tester.tap(_tip('Повтор выключен'));
    await _settle(tester);
    expect(c.player.repeat, Repeat.all);
    await tester.tap(_tip('Повтор всех треков'));
    await _settle(tester);
    expect(c.player.repeat, Repeat.one);
    engine.finish();
    await _settle(tester);
    expect(c.player.track!.title, 'Кукушка');

    await tester.tap(_tip('Следующий трек').first);
    await _settle(tester);
    expect(c.player.track!.title, 'Группа крови');

    await tester.tap(find.text('FLAC'));
    await _settle(tester);
    await tester.tap(find.text('Экономия трафика').last);
    await _settle(tester);
    expect(c.player.quality, PlayQuality.low);
    expect(engine.url, endsWith('q=low'));
    expect(find.text('MP3 192'), findsOneWidget);

    await tester.tap(_tip('Открыть плеер и очередь'));
    await _settle(tester);
    expect(find.text('Сейчас играет'), findsOneWidget);
    expect(find.text('Очередь'), findsOneWidget);
    expect(find.text('3 из 7'), findsOneWidget);
    final inPanel = find.descendant(of: find.byType(NowPlaying), matching: find.text('Перемен'));
    await tester.scrollUntilVisible(
      inPanel,
      100,
      scrollable: find.descendant(of: find.byType(NowPlaying), matching: find.byType(Scrollable)).last,
    );
    await tester.tap(inPanel);
    await _settle(tester);
    expect(c.player.track!.title, 'Перемен');
    expect(find.text('6 из 7'), findsOneWidget);
    expect(find.text('Кукушка'), findsWidgets);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await _settle(tester);
    expect(find.text('Сейчас играет'), findsNothing);

    await core.close();
  });

  testWidgets('горячие клавиши: пробел, Ctrl+стрелки и медиаклавиши', (tester) async {
    final (core, c, engine) = await _open(tester);
    await tester.tap(find.text('Дорога'));
    await _settle(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Слушать'));
    await _settle(tester);
    expect(c.player.track!.title, 'Звезда по имени Солнце');

    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(engine.isPlaying, isFalse);
    await tester.sendKeyEvent(LogicalKeyboardKey.mediaPlayPause);
    await tester.pump();
    expect(engine.isPlaying, isTrue);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await _settle(tester);
    expect(c.player.track!.title, 'Кукушка');

    await tester.tap(find.byType(TextField).first);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(engine.isPlaying, isTrue);

    await core.close();
  });

  test('оборванный поток не перескакивает, а продолжается с того же места', () {
    final sent = <Map<String, Object?>>[];
    final engine = SilentEngine();
    final p = PlayerState(sent.add, engine);
    Map<String, Object?> ev(String action, {double? start, bool offline = false}) => {
      'type': 'player',
      'action': action,
      'url': 'http://127.0.0.1/1',
      'start': ?start,
      'offline': offline,
      'loading': offline,
      'track': {'id': '1', 'title': 'Песня', 'durationMs': 180000},
    };

    p.receive(ev('play'));
    engine.progress(const Duration(seconds: 1));
    expect(sent.where((c) => c['cmd'] == 'playerStarted'), hasLength(1));
    engine.progress(const Duration(seconds: 60));
    engine.finish();
    expect(sent.last, containsPair('cmd', 'playerError'));
    expect(sent.last, containsPair('position', 61.0));
    expect(sent.where((c) => c['cmd'] == 'playerEnded'), isEmpty);

    p.receive(ev('', offline: true));
    expect(p.offline, isTrue);
    expect(p.loading, isTrue);

    p.receive(ev('retry', start: 61));
    expect(engine.at, const Duration(seconds: 61));
    expect(engine.isPlaying, isTrue);
    expect(p.offline, isFalse);
    engine.progress(const Duration(seconds: 1));
    expect(sent.where((c) => c['cmd'] == 'playerStarted'), hasLength(1));

    engine.progress(const Duration(seconds: 117));
    engine.finish();
    expect(sent.last, containsPair('cmd', 'playerEnded'));
  });

  group('плавный переход', () {
    Map<String, Object?> ev(String action, String id, {String? next, String kind = 'playlist', String repeat = 'off'}) => {
      'type': 'player',
      'action': action,
      'url': 'http://127.0.0.1/$id',
      'nextUrl': ?(next == null ? null : 'http://127.0.0.1/$next'),
      'next': ?(next == null ? null : {'id': next, 'title': 'Следующая', 'durationMs': 180000}),
      'repeat': repeat,
      'source': {'kind': kind, 'id': 'x'},
      'track': {'id': id, 'title': 'Песня', 'durationMs': 180000},
    };
    Iterable<Map<String, Object?>> cmds(List<Map<String, Object?>> sent, String cmd) =>
        sent.where((c) => c['cmd'] == cmd);

    test('заранее грузит следующий трек, сводит и не открывает его заново', () {
      final sent = <Map<String, Object?>>[];
      final engine = SilentEngine();
      final p = PlayerState(sent.add, engine)..crossfade = const Duration(seconds: 6);

      p.receive(ev('play', '1', next: '2'));
      engine.progress(const Duration(seconds: 1));
      engine.progress(const Duration(seconds: 150));
      expect(engine.preloaded, isNull);
      engine.progress(const Duration(seconds: 5));
      expect(engine.preloaded, 'http://127.0.0.1/2');
      expect(engine.fades, isEmpty);

      engine.progress(const Duration(seconds: 19));
      expect(engine.fades, [('http://127.0.0.1/2', const Duration(seconds: 5))]);
      expect(sent.last, {'cmd': 'playerEnded', 'track': '1', 'position': 180.0});

      engine.progress(const Duration(seconds: 5));
      expect(engine.isPlaying, isFalse);
      expect(engine.fades, hasLength(1));
      expect(cmds(sent, 'playerEnded'), hasLength(1));
      expect(cmds(sent, 'playerError'), isEmpty);
      expect(p.playing, isTrue);

      final opens = engine.opens;
      p.receive(ev('play', '2'));
      expect(engine.opens, opens);
      expect(engine.url, 'http://127.0.0.1/2');
      expect(engine.isPlaying, isTrue);
      engine.progress(const Duration(milliseconds: 500));
      expect(sent.last, {'cmd': 'playerStarted', 'track': '2'});
    });

    test('пауза во время перехода отменяет его, и следующий трек открывается как обычно', () {
      final sent = <Map<String, Object?>>[];
      final engine = SilentEngine();
      final p = PlayerState(sent.add, engine)..crossfade = const Duration(seconds: 6);

      p.receive(ev('play', '1', next: '2'));
      engine.progress(const Duration(seconds: 1));
      engine.progress(const Duration(seconds: 176));
      expect(engine.fades, hasLength(1));
      p.pause();
      expect(engine.fadingTo, isNull);

      final opens = engine.opens;
      p.receive(ev('play', '2'));
      expect(engine.opens, opens + 1);
    });

    for (final (name, crossfade, kind, repeat, next) in [
      ('выключен в настройках', Duration.zero, 'playlist', 'off', '2'),
      ('в альбоме', const Duration(seconds: 6), 'album', 'off', '2'),
      ('при повторе трека', const Duration(seconds: 6), 'playlist', 'one', '1'),
      ('в конце очереди', const Duration(seconds: 6), 'playlist', 'off', null),
    ]) {
      test('не включается $name', () {
        final sent = <Map<String, Object?>>[];
        final engine = SilentEngine();
        final p = PlayerState(sent.add, engine)..crossfade = crossfade;

        p.receive(ev('play', '1', next: next, kind: kind, repeat: repeat));
        engine.progress(const Duration(seconds: 1));
        engine.progress(const Duration(seconds: 177));
        expect(engine.preloaded, isNull);
        expect(engine.fades, isEmpty);
        expect(cmds(sent, 'playerEnded'), isEmpty);

        engine.progress(const Duration(seconds: 2));
        expect(cmds(sent, 'playerEnded'), hasLength(1));
      });
    }
  });

  test('после перезапуска трек ждёт на том же месте и сохраняет позицию', () {
    final sent = <Map<String, Object?>>[];
    final engine = SilentEngine();
    final p = PlayerState(sent.add, engine);
    p.receive({
      'type': 'player',
      'action': 'restore',
      'url': 'http://127.0.0.1/5',
      'start': 33.5,
      'track': {'id': '5', 'title': 'Песня', 'durationMs': 180000},
    });
    expect(engine.url, isNull);
    expect(p.position.value, const Duration(milliseconds: 33500));
    expect(p.duration.value, const Duration(minutes: 3));

    p.seek(const Duration(seconds: 40));
    expect(engine.url, isNull);
    p.togglePlay();
    expect(engine.url, 'http://127.0.0.1/5');
    expect(engine.at, const Duration(seconds: 40));
    expect(engine.isPlaying, isTrue);

    engine.progress(const Duration(seconds: 1));
    expect(sent.where((c) => c['cmd'] == 'playerStarted'), hasLength(1));
    engine.progress(const Duration(seconds: 10));
    expect(sent.last, containsPair('cmd', 'playerPosition'));
    expect(sent.last, containsPair('position', 51.0));

    p.pause();
    expect(sent.last, containsPair('cmd', 'playerPosition'));
    expect(sent.last, containsPair('on', true));
  });

  testWidgets('смена трека не дёргает кнопку и спиннер', (tester) async {
    final sent = <Map<String, Object?>>[];
    final engine = SilentEngine();
    final p = PlayerState(sent.add, engine);
    var changes = 0;
    p.addListener(() => changes++);
    Map<String, Object?> ev(String id) => {
      'type': 'player',
      'action': 'play',
      'url': 'http://127.0.0.1/$id',
      'track': {'id': id, 'title': 'Песня $id', 'durationMs': 180000},
    };

    p.receive(ev('1'));
    engine.progress(const Duration(seconds: 179));
    var flips = 0;
    var last = p.playing;
    p.addListener(() {
      if (p.playing != last) flips++;
      last = p.playing;
    });
    engine.progress(const Duration(seconds: 2));
    expect(sent.last, containsPair('cmd', 'playerEnded'));
    expect(p.playing, isTrue);
    p.receive(ev('2'));
    expect(p.playing, isTrue);
    expect(flips, 0);

    engine.buffer(true);
    await tester.pump(const Duration(milliseconds: 200));
    engine.buffer(false);
    expect(p.buffering, isFalse);
    engine.buffer(true);
    await tester.pump(const Duration(milliseconds: 600));
    expect(p.buffering, isTrue);
    engine.buffer(false);
    expect(p.buffering, isFalse);

    p.pause();
    expect(p.playing, isFalse);
    p.receive({...ev('2'), 'action': 'end'});
    expect(p.playing, isFalse);
    expect(changes, greaterThan(0));
    p.dispose();
  });

  test('обложка декодируется ступенями, а не под каждый пиксель', () {
    expect(coverDecodeSize(40, 1), 64);
    expect(coverDecodeSize(300, 1), 512);
    expect(coverDecodeSize(320, 1.5), 512);
    expect(coverDecodeSize(360, 1.5), 1024);
    expect(coverDecodeSize(4000, 2), 2048);
  });

  test('дни истории подписаны по-русски', () {
    final now = DateTime(2026, 11, 4, 0, 30);
    expect(dayLabel('2026-11-04', now), 'Сегодня');
    expect(dayLabel('2026-11-03', now), 'Вчера');
    expect(dayLabel('2026-11-02', now), '2 ноября');
    expect(dayLabel('2026-01-15', now), '15 января');
    expect(dayLabel('2025-12-31', now), '31 декабря 2025');
    expect(dayLabel('2026-02-28', DateTime(2026, 3, 1, 23)), 'Вчера');
    expect(dayLabel('2026-03-28', DateTime(2026, 3, 29, 12)), 'Вчера');
    expect(dayLabel('2026-10-24', DateTime(2026, 10, 25, 12)), 'Вчера');
    expect(dayLabel('вчера', now), 'вчера');
  });

  testWidgets('история: с главной по дням, запуск трека из нужного дня, лайк и назад', (tester) async {
    final (core, c, _) = await _open(tester);

    expect(find.text('Вы недавно слушали'), findsOneWidget);
    await tester.tap(find.text('Вся история'));
    await _settle(tester);
    expect(c.player.browse.value, sourceHistory);
    expect(find.text('ПРОСЛУШИВАНИЯ'), findsOneWidget);
    expect(find.text('История'), findsWidgets);
    expect(find.text('Сегодня'), findsOneWidget);
    expect(find.text('Вчера'), findsOneWidget);
    final now = DateTime.now();
    String ago(int days) => DateTime(now.year, now.month, now.day - days).toIso8601String().substring(0, 10);
    expect(find.text(dayLabel(ago(4), now)), findsOneWidget);
    expect(find.text('3 трека'), findsNWidgets(2));
    expect(find.text('Скачать'), findsNothing);

    final yesterday = find.byKey(ValueKey('${ago(1)}:1'));
    expect(yesterday, findsOneWidget);
    await tester.tap(yesterday);
    await _settle(tester);
    expect(c.player.track!.title, 'Звезда по имени Солнце');
    expect(c.player.source!.id, sourceHistory);
    expect(c.player.pos, 5);

    final row = find.ancestor(of: find.text('Ветер'), matching: find.byType(TrackRow));
    await tester.tap(find.descendant(of: row, matching: _tip('Мне нравится')));
    await _settle(tester);
    expect(find.descendant(of: row, matching: _tip('Убрать из «Мне нравится»')), findsOneWidget);
    await tester.tap(find.descendant(of: row, matching: _tip('Ещё')));
    await _settle(tester);
    expect(find.text('Скачать FLAC'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await _settle(tester);

    await tester.tap(find.text('Назад').first);
    await _settle(tester);
    expect(c.player.browse.value, sourceHome);
    expect(find.text('Для вас'), findsOneWidget);

    await tester.tap(find.text('История').first);
    await _settle(tester);
    expect(find.text('Сегодня'), findsOneWidget);
    await core.close();
  });

  testWidgets('история на телефоне открывается с главной и закрывается назад', (tester) async {
    final (core, c, _) = await _open(tester, size: const Size(320, 640));
    final more = find.text('Вся история');
    await tester.ensureVisible(more);
    await tester.pumpAndSettle();
    await tester.tap(more);
    await _settle(tester);
    expect(find.text('Сегодня'), findsOneWidget);
    await tester.tap(_tip('Назад'));
    await _settle(tester);
    expect(c.player.browsing.value, isFalse);
    expect(find.text('Вся история'), findsOneWidget);
    await core.close();
  });

  testWidgets('волна по плейлисту и по треку из меню', (tester) async {
    final (core, c, _) = await _open(tester);
    await tester.tap(find.text('Дорога'));
    await _settle(tester);
    await tester.tap(find.text('Волна по плейлисту'));
    await _settle(tester);
    expect(c.player.wave, isTrue);
    expect(c.player.source?.title, 'Моя волна: Дорога');
    expect(core.player.waves.single, contains('playlists'));

    await tester.tap(_tip('Ещё').last);
    await _settle(tester);
    await tester.tap(find.text('Моя волна по треку'));
    await _settle(tester);
    expect(core.player.waves, hasLength(2));
    expect(c.player.source?.title, startsWith('Моя волна: '));
    await core.close();
  });

  testWidgets('пустой плейлист предлагает Мою волну', (tester) async {
    final (core, c, _) = await _open(tester);
    await tester.tap(find.text('Пустой'));
    await _settle(tester);
    expect(find.text('В этом плейлисте пока нет треков'), findsOneWidget);
    await tester.tap(find.text('Включить Мою волну'));
    await _settle(tester);
    expect(c.player.wave, isTrue);
    expect(c.player.hasTrack, isTrue);
    await core.close();
  });

  for (final size in const [Size(360, 760), Size(320, 640)]) {
    testWidgets('телефон ${size.width.round()}: навигация снизу, мини-плеер и полный экран', (tester) async {
      final (core, c, _) = await _open(tester, size: size);

      expect(find.byType(NavigationBar), findsOneWidget);
      await tester.tap(find.text('Моя волна'));
      await _settle(tester);
      expect(c.player.hasTrack, isTrue);

      await tester.tap(find.bySemanticsLabel(RegExp('^Открыть плеер')).first);
      await _settle(tester);
      expect(find.text('Сейчас играет'), findsOneWidget);
      expect(_tip('Свернуть плеер'), findsOneWidget);
      expect(find.byType(QueueRow), findsNothing);
      await tester.tap(_tip('Очередь'));
      await _settle(tester);
      expect(find.byType(QueueRow), findsWidgets);
      await tester.tap(_tip('Закрыть очередь'));
      await _settle(tester);
      expect(find.byType(QueueRow), findsNothing);

      final popped = await tester.binding.handlePopRoute();
      await _settle(tester);
      expect(popped, isTrue);
      expect(find.text('Сейчас играет'), findsNothing);

      expect(find.text('Для вас'), findsOneWidget);
      await tester.tap(find.text('Коллекция'));
      await _settle(tester);
      expect(c.section.value, Section.collection);
      await tester.tap(find.text('Мне нравится'));
      await _settle(tester);
      expect(_tip('К коллекции'), findsOneWidget);
      await tester.tap(_tip('К коллекции'));
      await _settle(tester);
      expect(find.text('Дорога'), findsOneWidget);
      final toHome = await tester.binding.handlePopRoute();
      await _settle(tester);
      expect(toHome, isTrue);
      expect(c.section.value, Section.home);

      await tester.tap(find.text('Поиск'));
      await _settle(tester);
      expect(c.section.value, Section.search);
      expect(find.text('Найдите музыку'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('^Открыть плеер')), findsWidgets);
      final back = await tester.binding.handlePopRoute();
      await _settle(tester);
      expect(back, isTrue);
      expect(c.section.value, Section.home);

      await core.close();
    });
  }

  testWidgets('трек из поиска можно сразу послушать', (tester) async {
    final (core, c, engine) = await _open(tester);
    await tester.enterText(find.byType(TextField), 'кино');
    await tester.pump(const Duration(milliseconds: 450));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pumpAndSettle();
    expect(c.search.open, isTrue);
    await tester.tap(_tip('Слушать').first);
    await _settle(tester);
    expect(c.player.hasTrack, isTrue);
    expect(engine.isPlaying, isTrue);
    await core.close();
  });

  testWidgets('ошибки: три подряд останавливают плеер, ошибка посреди трека не перескакивает', (tester) async {
    final (core, c, engine) = await _open(tester);
    await tester.tap(find.text('Дорога'));
    await _settle(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Слушать'));
    await _settle(tester);

    final first = c.player.track!.id;
    engine.progress(const Duration(seconds: 1));
    engine.progress(const Duration(seconds: 9));
    engine.fail('decoder glitch');
    await _settle(tester);
    expect(core.player.failed, isEmpty);
    expect(c.player.track!.id, first);

    await tester.tap(_tip('Следующий трек').first);
    await _settle(tester);
    for (var i = 0; i < 3; i++) {
      engine.fail('HTTP 404');
      engine.fail('HTTP 404 again');
      await _settle(tester);
    }
    expect(core.player.failed, hasLength(3));
    expect(find.text('Не удаётся воспроизвести треки'), findsOneWidget);
    engine.fail('HTTP 404');
    await _settle(tester);
    expect(core.player.failed, hasLength(3));
    await core.close();
  });

  testWidgets('поиск: трек играет, исполнитель и альбом открываются страницами', (tester) async {
    final (core, c, engine) = await _open(tester);
    await tester.enterText(find.byType(TextField), 'кино');
    await tester.pump(const Duration(milliseconds: 450));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Война'));
    await _settle(tester);
    expect(c.player.hasTrack, isTrue);
    expect(engine.isPlaying, isTrue);

    await tester.tap(find.descendant(of: find.byType(BestCard), matching: find.text('Кино')).first);
    await _settle(tester);
    expect(c.section.value, Section.home);
    expect(find.text('ИСПОЛНИТЕЛЬ'), findsOneWidget);
    expect(find.text('Популярные треки'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('1988 · Альбом'), 200, scrollable: find.byType(Scrollable).last);
    await tester.ensureVisible(find.text('1988 · Альбом'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('1988 · Альбом'));
    await _settle(tester);
    expect(find.text('АЛЬБОМ'), findsOneWidget);
    expect(find.textContaining('Кино · 1988'), findsOneWidget);

    await tester.tap(find.text('Перемен'));
    await _settle(tester);
    expect(c.player.track!.title, 'Перемен');
    expect(c.player.source!.kind, 'album');

    await tester.tap(find.text('Назад'));
    await _settle(tester);
    expect(c.player.browse.value, contains('/artist/'));
    expect(find.byType(AlbumCard), findsWidgets);
    await tester.tap(find.text('Дорога'));
    await _settle(tester);
    expect(find.text('Назад'), findsNothing);
    await core.close();
  });

  testWidgets('из плеера: исполнитель, альбом и источник открываются страницами', (tester) async {
    final (core, c, _) = await _open(tester);
    c.player.play(fakePlaylist);
    await _settle(tester);
    expect(c.player.track!.title, 'Звезда по имени Солнце');
    expect(c.section.value, Section.home);

    c.player.panelOpen.value = true;
    await _settle(tester);
    await _tapLink(tester, _panel(_link('Кино')));
    await _settle(tester);
    expect(c.player.panelOpen.value, isFalse);
    expect(c.section.value, Section.home);
    expect(c.player.browse.value, fakeArtist('Кино'));
    expect(find.text('ИСПОЛНИТЕЛЬ'), findsOneWidget);
    expect(find.text('Назад'), findsOneWidget);

    c.player.panelOpen.value = true;
    await _settle(tester);
    await _tapLink(tester, _panel(_link('Звезда по имени Солнце')));
    await _settle(tester);
    expect(c.player.panelOpen.value, isFalse);
    expect(c.player.browse.value, fakeAlbum);
    expect(find.text('АЛЬБОМ'), findsOneWidget);
    expect(find.text('Назад'), findsOneWidget);
    expect(_link('Кино · 1988 · 8 треков · 36 мин'), findsOneWidget);

    await tester.tap(find.descendant(of: find.byType(TrackRow), matching: _tip('Ещё')).first);
    await _settle(tester);
    expect(find.text('Перейти к альбому'), findsNothing);
    await tester.tap(find.text('Перейти к исполнителю'));
    await _settle(tester);
    expect(c.player.browse.value, fakeArtist('Кино'));

    c.player.panelOpen.value = true;
    await _settle(tester);
    await tester.tap(_panel(_tip('Ещё')));
    await _settle(tester);
    await tester.tap(find.text('Перейти к альбому'));
    await _settle(tester);
    expect(c.player.browse.value, fakeAlbum);

    c.player.panelOpen.value = true;
    await _settle(tester);
    await _tapLink(tester, _panel(_link('Дорога')));
    await _settle(tester);
    expect(c.player.browse.value, fakePlaylist);
    expect(find.text('ПЛЕЙЛИСТ'), findsOneWidget);

    await _tapLink(tester, find.descendant(of: find.byType(TrackRow), matching: _link('Аквариум')).first);
    await _settle(tester);
    expect(c.player.browse.value, fakeArtist('Аквариум'));
    await tester.tap(find.text('Назад'));
    await _settle(tester);
    expect(c.player.browse.value, fakePlaylist);
    await core.close();
  });

  testWidgets('страница исполнителя: сетка популярных, все треки, релизы по разделам', (tester) async {
    final (core, c, _) = await _open(tester);
    final kino = fakeArtist('Кино');
    c.openPage(kino);
    await _settle(tester);
    expect(find.text('ИСПОЛНИТЕЛЬ'), findsOneWidget);
    expect(find.text('3 альбома · 1 сингл · 1 сборник'), findsOneWidget);
    expect(find.byType(TrackRow), findsNWidgets(6));
    expect(_link('Кино'), findsNothing);

    await tester.tap(find.byType(TrackRow).at(1));
    await _settle(tester);
    expect(c.player.source!.id, kino);
    expect(c.player.track!.title, 'Кукушка');

    await tester.tap(find.text('Все треки'));
    await _settle(tester);
    expect(c.player.browse.value, topTracksOf(kino));
    expect(find.text('ПОПУЛЯРНЫЕ ТРЕКИ'), findsOneWidget);
    expect(find.text('Альбомы'), findsNothing);
    await tester.scrollUntilVisible(find.text('Танец на цыпочках'), 200, scrollable: find.byType(Scrollable).last);
    expect(find.text('Танец на цыпочках'), findsOneWidget);
    await tester.drag(find.byType(Scrollable).last, const Offset(0, 5000));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Назад'));
    await _settle(tester);
    expect(c.player.browse.value, kino);

    final scroll = find.byType(Scrollable).last;
    await tester.scrollUntilVisible(find.text('Сборники'), 200, scrollable: scroll);
    await tester.drag(scroll, const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(find.text('Синглы и EP'), findsOneWidget);
    final cards = tester.widgetList<AlbumCard>(find.byType(AlbumCard)).map((w) => w.album.title).toList();
    expect(cards, ['Чёрный альбом', 'Звезда по имени Солнце', 'Группа крови', 'Кукушка', 'Последний герой']);
    await tester.ensureVisible(find.byType(AlbumCard).first);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(AlbumCard).first);
    await _settle(tester);
    expect(c.player.browse.value, 'https://music.yandex.ru/album/13');
    await core.close();
  });

  testWidgets('страница исполнителя на телефоне: три популярных трека', (tester) async {
    final (core, c, _) = await _open(tester, size: const Size(380, 800));
    c.openPage(fakeArtist('Кино'));
    await _settle(tester);
    expect(find.byType(TrackRow), findsNWidgets(3));
    expect(find.text('Все треки'), findsOneWidget);
    await core.close();
  });

  testWidgets('очередь в плеере: исполнитель открывается, название переключает трек', (tester) async {
    final (core, c, _) = await _open(tester);
    c.player.play(fakePlaylist);
    await _settle(tester);
    c.player.panelOpen.value = true;
    await _settle(tester);
    final row = find.descendant(of: find.byType(QueueRow), matching: _link('Аквариум'));
    await _tapLink(tester, row);
    await _settle(tester);
    expect(c.player.panelOpen.value, isFalse);
    expect(c.player.browse.value, fakeArtist('Аквариум'));
    expect(find.text('Аквариум'), findsWidgets);
    expect(c.player.track!.title, 'Звезда по имени Солнце');
    await core.close();
  });

  testWidgets('текст песни: строки по времени, перемотка по строке, обычный текст и его отсутствие', (tester) async {
    final (core, c, engine) = await _open(tester);
    c.player.play(fakePlaylist);
    await _settle(tester);
    c.player.panelOpen.value = true;
    await _settle(tester);

    await tester.tap(_panel(_tip('Текст песни')));
    await _settle(tester);
    expect(c.player.lyricsOpen.value, isTrue);
    expect(find.text('Строка 1'), findsOneWidget);
    expect(find.text('Авторы: Автор песни'), findsOneWidget);

    engine.progress(const Duration(seconds: 31));
    await _settle(tester);
    expect(c.player.lyrics['1']!.lineAt(c.player.position.value), 2);
    await tester.tap(find.text('Строка 6'));
    await _settle(tester);
    expect(engine.at, const Duration(seconds: 75));

    await tester.tap(_panel(_tip('Следующий трек')));
    await _settle(tester);
    expect(c.player.track!.title, 'Кукушка');
    expect(find.text('Строка 8'), findsOneWidget);
    await tester.tap(find.text('Строка 2'));
    await _settle(tester);
    expect(engine.at, lessThan(const Duration(seconds: 5)));

    await tester.tap(_panel(_tip('Следующий трек')));
    await _settle(tester);
    expect(find.text('Для этого трека нет текста'), findsOneWidget);

    await tester.tap(_panel(_tip('Обложка и очередь')));
    await _settle(tester);
    expect(c.player.lyricsOpen.value, isFalse);
    expect(find.text('Очередь'), findsOneWidget);
    await core.close();
  });

  testWidgets('поделиться: трек из плеера и страница плейлиста копируют ссылку', (tester) async {
    final (core, c, _) = await _open(tester);
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied.add('${(call.arguments as Map)['text']}');
      return null;
    });
    c.player.play(fakePlaylist);
    await _settle(tester);
    c.player.panelOpen.value = true;
    await _settle(tester);
    await tester.tap(_panel(_tip('Ещё')));
    await _settle(tester);
    await tester.tap(find.text('Поделиться треком'));
    await tester.pump();
    await tester.pump();
    expect(copied, ['https://music.yandex.ru/album/9/track/1']);
    expect(find.text('Ссылка скопирована'), findsOneWidget);

    c.player.panelOpen.value = false;
    c.openPage(fakePlaylist);
    await _settle(tester);
    await tester.tap(find.widgetWithText(OutlinedButton, 'Поделиться'));
    await tester.pump();
    await tester.pump();
    expect(copied.last, fakePlaylist);
    await core.close();
  });

  testWidgets('выход из аккаунта останавливает плеер', (tester) async {
    final (core, c, engine) = await _open(tester);
    await tester.tap(find.text('Моя волна'));
    await _settle(tester);
    expect(engine.isPlaying, isTrue);
    c.logout();
    await _settle(tester);
    expect(engine.isPlaying, isFalse);
    expect(c.player.hasTrack, isFalse);
    await core.close();
  });

  for (final wave in [false, true]) {
    testWidgets('ничего не вылезает за край от 320 до 1400 px, wave=$wave', (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final core = FakeCore();
      final c = Controller(core, engine: SilentEngine());
      await tester.pumpWidget(YmdApp(controller: c));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Вставить токен вручную'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'good');
      await tester.pump();
      await tester.tap(find.text('Войти'));
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pumpAndSettle();
      c.home();
      await tester.pumpAndSettle();
      if (wave) {
        c.player.play('wave');
      } else {
        await tester.tap(find.text('Дорога'));
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Город золотой'));
      }
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      for (final open in [false, true]) {
        c.player.panelOpen.value = open;
        for (var w = 320.0; w <= 1400; w += 40) {
          for (final h in [560.0, 760.0]) {
            tester.view.physicalSize = Size(w, h);
            await tester.pumpAndSettle();
          }
        }
      }
      c.player.lyricsOpen.value = true;
      for (var w = 320.0; w <= 1400; w += 40) {
        for (final h in [560.0, 760.0]) {
          tester.view.physicalSize = Size(w, h);
          await tester.pumpAndSettle();
        }
      }
      c.player.lyricsOpen.value = false;
      c.player.panelOpen.value = false;
      for (final page in [fakeArtist('Кино'), sourceHistory]) {
        c.openPage(page);
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pumpAndSettle();
        for (var w = 320.0; w <= 1400; w += 40) {
          tester.view.physicalSize = Size(w, 760);
          await tester.pumpAndSettle();
          await tester.drag(find.byType(Scrollable).last, const Offset(0, -2000));
          await tester.pumpAndSettle();
          await tester.drag(find.byType(Scrollable).last, const Offset(0, 2000));
          await tester.pumpAndSettle();
        }
      }
      await core.close();
    });
  }
}
