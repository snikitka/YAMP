import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:yamp/player/engine.dart';
import 'package:yamp/player/system_media.dart';
import 'package:yamp/state/player.dart';

const _channel = MethodChannel('test/media');

Map<String, Object?> _player(String action, {String id = '1', String title = 'Песня'}) => {
  'type': 'player',
  'action': action,
  'url': 'http://127.0.0.1/$id',
  'art': 'https://covers/$id',
  'track': {'id': id, 'title': title, 'artist': 'Группа', 'album': 'Альбом', 'durationMs': 180000},
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late List<MethodCall> calls;
  late List<Map<String, Object?>> sent;
  late SilentEngine engine;
  late PlayerState player;
  late SystemMedia media;

  setUp(() {
    calls = [];
    sent = [];
    messenger.setMockMethodCallHandler(_channel, (call) async {
      calls.add(call);
      return null;
    });
    engine = SilentEngine();
    player = PlayerState(sent.add, engine);
    final now = DateTime(2026);
    media = SystemMedia(player, channel: _channel, clock: () => now);
  });

  tearDown(() {
    media.dispose();
    messenger.setMockMethodCallHandler(_channel, null);
  });

  Future<void> command(String method, [Object? args]) async {
    await messenger.handlePlatformMessage(
      _channel.name,
      const StandardMethodCodec().encodeMethodCall(MethodCall(method, args)),
      (_) {},
    );
  }

  Map<String, Object?> last() => Map<String, Object?>.from(calls.last.arguments as Map);

  test('трек и пауза уходят в системные контролы', () async {
    player.receive(_player('play'));
    await Future<void>.delayed(Duration.zero);
    expect(calls.last.method, 'update');
    expect(last(), containsPair('title', 'Песня'));
    expect(last(), containsPair('artist', 'Группа'));
    expect(last(), containsPair('art', 'https://covers/1'));
    expect(last(), containsPair('duration', 180000));
    expect(last(), containsPair('playing', true));

    final before = calls.length;
    player.receive(_player('play'));
    await Future<void>.delayed(Duration.zero);
    expect(calls.length, before);

    await engine.pause();
    await Future<void>.delayed(Duration.zero);
    expect(last(), containsPair('playing', false));

    player.receive({'type': 'player', 'action': 'stop'});
    await Future<void>.delayed(Duration.zero);
    expect(calls.last.method, 'stop');
  });

  test('позиция уходит только при скачке', () async {
    player.receive(_player('play'));
    await Future<void>.delayed(Duration.zero);
    final updates = calls.length;

    engine.progress(const Duration(seconds: 1));
    await Future<void>.delayed(Duration.zero);
    expect(calls.length, updates);

    player.seek(const Duration(seconds: 90));
    await Future<void>.delayed(Duration.zero);
    expect(calls.length, updates + 1);
    expect(last(), containsPair('position', 90000));
  });

  test('команды из уведомления управляют плеером', () async {
    player.receive(_player('play'));
    await Future<void>.delayed(Duration.zero);

    await command('pause');
    expect(engine.isPlaying, isFalse);
    await command('play');
    expect(engine.isPlaying, isTrue);
    await command('seek', 42000);
    expect(engine.at, const Duration(seconds: 42));
    await command('next');
    expect(sent.last, containsPair('cmd', 'playerNext'));
    await command('previous');
    expect(sent.last, containsPair('cmd', 'playerPrev'));
    await command('stop');
    expect(engine.isPlaying, isFalse);
  });

  test('лайк и дизлайк из уведомления', () async {
    player.receive(_player('play'));
    await Future<void>.delayed(Duration.zero);
    expect(last(), containsPair('liked', false));

    await command('like');
    expect(sent.last, containsPair('cmd', 'like'));
    expect(sent.last, containsPair('on', true));

    player.receive({'type': 'mark', 'track': '1', 'liked': true, 'disliked': false, 'likedCount': 1});
    await Future<void>.delayed(Duration.zero);
    expect(last(), containsPair('liked', true));

    await command('like');
    expect(sent.last, containsPair('on', false));

    await command('dislike');
    expect(sent.last, containsPair('cmd', 'dislike'));
    expect(sent.last, containsPair('on', true));
  });

  test('без libmpv плеер не запускается и объясняет почему', () {
    final blocked = <String>[];
    final p = PlayerState(sent.add, UnavailableEngine('нет libmpv'))..onBlocked = blocked.add;
    p.play(sourceWave);
    p.togglePlay();
    p.playShuffled(sourceLiked);
    expect(blocked, ['нет libmpv', 'нет libmpv', 'нет libmpv']);
    expect(sent.where((c) => c['cmd'] == 'play'), isEmpty);
    expect(p.unavailable, 'нет libmpv');
    expect(PlayerState(sent.add, SilentEngine()).unavailable, isEmpty);
  });
}
