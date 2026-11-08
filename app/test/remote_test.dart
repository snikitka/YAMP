import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'package:yamp/core/core.dart';
import 'package:yamp/core/fake_core.dart';
import 'package:yamp/core/fake_remote.dart';
import 'package:yamp/player/engine.dart';
import 'package:yamp/state/controller.dart';
import 'package:yamp/state/remote.dart';
import 'package:yamp/theme.dart';
import 'package:yamp/ui/remote_page.dart';
import 'package:yamp/ui/settings_dialog.dart';

class _ScriptCore implements Core {
  final _events = StreamController<Event>();
  final sent = <Map<String, Object?>>[];

  void push(Event e) => _events.add(e);

  @override
  Stream<Event> get events => _events.stream;

  Map<String, Object?> get lastPosition => sent.lastWhere((c) => c['cmd'] == 'playerPosition');

  @override
  void send(Map<String, Object?> command) => sent.add(command);

  @override
  Future<void> close() => _events.close();
}

Widget _app(Widget home) => MaterialApp(theme: buildTheme(Brightness.dark), home: home);

void _size(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

void main() {
  test('пульт: позиция идёт сама, чужие события и громкость под пальцем', () {
    var now = DateTime(2026, 11, 5, 12);
    final sent = <Map<String, Object?>>[];
    final r = RemoteState(sent.add, clock: () => now);
    addTearDown(r.dispose);

    r.receive({
      'type': 'remoteDevices',
      'devices': [
        {'id': 'pc', 'name': 'Комп', 'paired': true, 'online': true},
      ],
    });
    r.connect(r.devices.single);
    expect(r.status, LinkStatus.connecting);
    r.togglePlay();
    expect(sent.where((c) => c['cmd'] == 'remoteSend'), isEmpty, reason: 'без связи команды не уходят');

    r.receive({'type': 'remoteLink', 'id': 'pc', 'name': 'Комп', 'status': 'online'});
    r.receive({
      'type': 'remoteEvent',
      'id': 'pc',
      'event': {
        'type': 'player',
        'track': {'id': 'a', 'title': 'A', 'durationMs': 100000},
        'volume': 0.5,
      },
    });
    r.receive({
      'type': 'remoteEvent',
      'id': 'pc',
      'event': {'type': 'playback', 'track': 'a', 'playing': true, 'position': 10, 'volume': 0.5},
    });
    now = now.add(const Duration(seconds: 3));
    expect(r.at, const Duration(seconds: 13));
    now = now.add(const Duration(minutes: 5));
    expect(r.at, const Duration(seconds: 100), reason: 'позиция не уходит за длину трека');

    r.receive({
      'type': 'remoteEvent',
      'id': 'other',
      'event': {
        'type': 'player',
        'track': {'id': 'z'},
      },
    });
    expect(r.track?.id, 'a');

    r.togglePlay();
    expect(r.playing, isFalse);
    expect(sent.last, {
      'cmd': 'remoteSend',
      'command': {'cmd': 'pause'},
    });

    r.setVolume(0.2);
    r.setVolume(0.25);
    r.setVolume(0.3, done: true);
    final volumes = [
      for (final c in sent)
        if ((c['command'] as Map?)?['cmd'] == 'volume') (c['command'] as Map)['volume'],
    ];
    expect(volumes, [0.2, 0.3]);
    r.receive({
      'type': 'remoteEvent',
      'id': 'pc',
      'event': {'type': 'playback', 'track': 'a', 'playing': false, 'position': 20, 'volume': 0.9},
    });
    expect(r.volume, 0.3, reason: 'пока палец на ползунке, старое значение с компьютера не дёргает его');
    now = now.add(const Duration(seconds: 2));
    r.receive({
      'type': 'remoteEvent',
      'id': 'pc',
      'event': {'type': 'playback', 'track': 'a', 'playing': false, 'position': 20, 'volume': 0.3},
    });
    expect(r.at, const Duration(seconds: 20));

    r.receive({
      'type': 'remoteEvent',
      'id': 'pc',
      'event': {
        'type': 'player',
        'track': {'id': 'b', 'durationMs': 90000},
      },
    });
    expect(r.at, Duration.zero, reason: 'новый трек начинается с нуля');

    r.receive({
      'type': 'remoteLink',
      'id': 'pc',
      'status': 'failed',
      'message': 'Компьютер больше не узнаёт этот телефон',
    });
    expect(r.connected, isFalse);
    expect(r.linkMessage, contains('не узнаёт'));
  });

  test('компьютер выполняет команды пульта и сообщает, играет ли он', () async {
    final core = _ScriptCore();
    final engine = SilentEngine();
    final c = Controller(core, engine: engine);
    addTearDown(c.dispose);

    core.push({
      'type': 'player',
      'action': 'play',
      'track': {'id': '1', 'title': 'Ветер', 'durationMs': 300000},
      'url': 'http://127.0.0.1/1',
      'volume': 0.8,
    });
    await Future<void>.delayed(Duration.zero);
    expect(engine.isPlaying, isTrue);
    expect(core.lastPosition, {'cmd': 'playerPosition', 'track': '1', 'position': 0.0, 'playing': true});

    core.push({'type': 'remote', 'action': 'pause'});
    await Future<void>.delayed(Duration.zero);
    expect(engine.isPlaying, isFalse);
    expect(core.lastPosition, {'cmd': 'playerPosition', 'track': '1', 'position': 0.0, 'playing': false, 'on': true});

    core.push({'type': 'remote', 'action': 'seek', 'position': 30.5});
    await Future<void>.delayed(Duration.zero);
    expect(engine.at, const Duration(milliseconds: 30500));
    expect(core.lastPosition, {'cmd': 'playerPosition', 'track': '1', 'position': 30.5, 'playing': false});

    core.push({'type': 'remote', 'action': 'resume'});
    await Future<void>.delayed(Duration.zero);
    expect(engine.isPlaying, isTrue);
    expect(core.lastPosition['playing'], isTrue);

    core.push({'type': 'remote', 'action': 'volume', 'volume': 0.25});
    await Future<void>.delayed(Duration.zero);
    expect(engine.volume, 0.25);
    expect(core.sent.last, {'cmd': 'playerVolume', 'volume': 0.25});
  });

  testWidgets('телефон: связывание по QR и управление компьютером', (tester) async {
    _size(tester, const Size(400, 860));
    final core = FakeCore();
    final c = Controller(core);
    await tester.pumpWidget(_app(RemotePage(c: c, scanner: (_) async => fakePairLink)));
    await _settle(tester);

    expect(find.text('Рядом в сети'), findsOneWidget);
    expect(find.text(FakeRemote.pcName), findsOneWidget);

    await tester.tap(find.text('Сканировать QR-код'));
    await _settle(tester);
    expect(find.text('Ветер'), findsWidgets);
    expect(find.text(FakeRemote.pcName), findsOneWidget);

    await tester.tap(find.byTooltip('Пауза'));
    await _settle(tester);
    expect(core.remote.sent.last, {'cmd': 'pause'});
    expect(find.byTooltip('Слушать'), findsOneWidget);

    await tester.tap(find.byTooltip('Следующий трек'));
    await _settle(tester);
    expect(core.remote.sent.last, {'cmd': 'playerNext', 'track': 'r1'});
    expect(find.text('Перемен'), findsWidgets);

    await tester.tap(find.byTooltip('Мне нравится'));
    await _settle(tester);
    expect(find.byTooltip('Убрать из «Мне нравится»'), findsOneWidget);

    await tester.tap(find.byTooltip('Отключиться'));
    await _settle(tester);
    expect(find.text('Связанные компьютеры'), findsOneWidget);

    await tester.tap(find.text(FakeRemote.pcName));
    await _settle(tester);
    expect(find.byTooltip('Отключиться'), findsOneWidget);

    await tester.tap(find.byTooltip('Отключиться'));
    await _settle(tester);
    await tester.tap(find.byTooltip('Отвязать'));
    await _settle(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Отвязать'));
    await _settle(tester);
    expect(find.text('Связанные компьютеры'), findsNothing);
    expect(find.text('Рядом в сети'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });

  testWidgets('экран пульта помещается на узких и низких телефонах', (tester) async {
    final core = FakeCore();
    final c = Controller(core);
    for (final size in const [Size(320, 560), Size(360, 740), Size(412, 915), Size(800, 400)]) {
      _size(tester, size);
      await tester.pumpWidget(_app(RemotePage(c: c, scanner: (_) async => fakePairLink)));
      await _settle(tester);
      expect(tester.takeException(), isNull, reason: 'список компьютеров на $size');
      await tester.tap(find.text('Сканировать QR-код'));
      await _settle(tester);
      expect(find.byTooltip('Отключиться'), findsOneWidget);
      expect(tester.takeException(), isNull, reason: 'пульт на $size');
      await tester.tap(find.byTooltip('Отключиться'));
      await _settle(tester);
      await tester.tap(find.byTooltip('Отвязать'));
      await _settle(tester);
      await tester.tap(find.widgetWithText(FilledButton, 'Отвязать'));
      await _settle(tester);
      await tester.pumpWidget(const SizedBox());
    }
    c.dispose();
  });

  testWidgets('компьютер: QR-код в настройках и список связанных телефонов', (tester) async {
    _size(tester, const Size(1280, 860));
    final core = FakeCore();
    final c = Controller(core);
    await tester.pumpWidget(
      _app(
        Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(onPressed: () => showSettingsDialog(context, c), child: const Text('Настройки')),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Настройки'));
    await _settle(tester);
    await tester.tap(find.text('Пульт с телефона'));
    await _settle(tester);
    expect(find.text('Пока ни одного. Без связывания компьютер не принимает команды ни от кого.'), findsOneWidget);

    await tester.tap(find.text('Показать QR-код'));
    await _settle(tester);
    expect(find.byType(QrImageView), findsOneWidget);
    expect(find.textContaining('действует ещё'), findsOneWidget);

    core.remote.pairPhone('Pixel 9');
    await _settle(tester);
    expect(find.byType(QrImageView), findsNothing);
    expect(find.text('Pixel 9'), findsOneWidget);
    expect(find.text('Подключён сейчас'), findsOneWidget);

    await tester.tap(find.text('Отвязать'));
    await _settle(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Отвязать'));
    await _settle(tester);
    expect(find.text('Pixel 9'), findsNothing);
    expect(core.remote.phones, isEmpty);

    await tester.tap(find.text('Показать QR-код'));
    await _settle(tester);
    await tester.tap(find.byTooltip('Закрыть'));
    await _settle(tester);
    expect(find.byType(QrImageView), findsNothing);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });

  test('выбор музыки: запуск уходит на компьютер, а без режима играет телефон', () async {
    final core = _ScriptCore();
    final c = Controller(core, engine: SilentEngine());
    addTearDown(c.dispose);
    final notices = <String>[];
    final sub = c.notices.listen((n) => notices.add(n.message));
    addTearDown(sub.cancel);
    final r = c.remote;
    List<Object?> remoteCommands(int from) => [
      for (final s in core.sent.skip(from))
        if (s['cmd'] == 'remoteSend') s['command'],
    ];

    c.player.play('liked', track: '7', index: 2);
    expect(core.sent.last, {'cmd': 'play', 'source': 'liked', 'track': '7', 'index': 2});

    r.browse();
    expect(r.targeting, isFalse, reason: 'без компьютера режим не включается');

    r.receive({
      'type': 'remoteDevices',
      'devices': [
        {'id': 'pc', 'name': 'Комп', 'paired': true, 'online': true},
      ],
    });
    r.connect(r.devices.single);
    r.receive({'type': 'remoteLink', 'id': 'pc', 'name': 'Комп', 'status': 'online'});
    r.browse();
    expect(r.targeting, isTrue);

    final before = core.sent.length;
    c.player.play('https://music.yandex.ru/album/1', track: '5', index: 3);
    c.player.playShuffled('https://music.yandex.ru/users/me/playlists/3');
    c.player.playWave(source: 'https://music.yandex.ru/artist/9', title: 'Кино');
    expect(remoteCommands(before), [
      {'cmd': 'play', 'source': 'https://music.yandex.ru/album/1', 'track': '5', 'index': 3},
      {'cmd': 'playerShuffle', 'on': true},
      {'cmd': 'play', 'source': 'https://music.yandex.ru/users/me/playlists/3', 'index': -1},
      {'cmd': 'wave', 'source': 'https://music.yandex.ru/artist/9', 'title': 'Кино'},
    ]);
    expect(
      core.sent.skip(before).where((s) => s['cmd'] != 'remoteSend'),
      isEmpty,
      reason: 'локальный плеер не трогаем',
    );

    await Future<void>.delayed(Duration.zero);
    expect(notices, hasLength(3));
    expect(notices, everyElement('Включаю на компьютере «Комп»'));

    r.receive({'type': 'remoteLink', 'id': 'pc', 'status': 'offline', 'message': 'нет связи'});
    final offline = core.sent.length;
    c.player.play('chart');
    expect(core.sent.length, offline, reason: 'без связи команда никуда не уходит');
    await Future<void>.delayed(Duration.zero);
    expect(notices.last, contains('Нет связи'));

    r.disconnect();
    expect(r.targeting, isFalse);
    c.player.play('chart');
    expect(core.sent.last, {'cmd': 'play', 'source': 'chart', 'index': 0});
  });

  testWidgets('телефон: «Выбрать музыку» оставляет связь и показывает полосу компьютера', (tester) async {
    _size(tester, const Size(400, 860));
    final core = FakeCore();
    final c = Controller(core);
    await tester.pumpWidget(
      _app(
        Scaffold(
          body: Column(
            children: [
              Expanded(
                child: Builder(
                  builder: (context) => Center(
                    child: TextButton(onPressed: () => openRemote(context, c), child: const Text('Открыть пульт')),
                  ),
                ),
              ),
              RemoteBar(c: c),
            ],
          ),
        ),
      ),
    );
    await tester.tap(find.text('Открыть пульт'));
    await _settle(tester);
    c.remote.pair(fakePairLink);
    await _settle(tester);
    expect(find.text('Ветер'), findsWidgets);

    final pick = find.text('Выбрать музыку');
    await tester.scrollUntilVisible(pick, 200, scrollable: find.byType(Scrollable).first);
    await tester.tap(pick);
    await _settle(tester);
    await tester.pumpAndSettle();

    expect(find.byType(RemotePage), findsNothing);
    expect(c.remote.connected, isTrue, reason: 'уход с пульта не рвёт связь');
    expect(find.text(FakeRemote.pcName), findsOneWidget);
    expect(find.text('Выбранная музыка включится на компьютере'), findsOneWidget);

    c.player.play('https://music.yandex.ru/album/1', index: 2);
    await _settle(tester);
    expect(core.remote.sent.last, {'cmd': 'play', 'source': 'https://music.yandex.ru/album/1', 'index': 2});

    await tester.tap(find.text(FakeRemote.pcName));
    await _settle(tester);
    expect(find.byType(RemotePage), findsOneWidget);
    expect(find.text('Город золотой'), findsWidgets);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(RemotePage), findsNothing);
    expect(c.remote.connected, isTrue, reason: 'назад из пульта в режиме выбора музыки тоже не рвёт связь');

    await tester.tap(find.byTooltip('Отключить пульт'));
    await _settle(tester);
    expect(c.remote.linkId, isEmpty);
    expect(find.text('Выбранная музыка включится на компьютере'), findsNothing);

    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });
}
