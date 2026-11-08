import 'dart:math';

import 'core.dart';

const fakePlaylist = 'https://music.yandex.ru/users/ivan.petrov/playlists/1001';
const fakeEmptyPlaylist = 'https://music.yandex.ru/users/ivan.petrov/playlists/1002';
const fakeAlbum = 'https://music.yandex.ru/album/9';

String fakeArtist(String name) => 'https://music.yandex.ru/artist/${name.hashCode.abs() % 1000}';

class FakePlayer {
  FakePlayer(this._emit, this._later);

  final void Function(Event) _emit;
  final void Function(Duration, void Function()) _later;

  static const _songs = [
    ('Звезда по имени Солнце', 'Кино', 225000),
    ('Кукушка', 'Кино', 396000),
    ('Группа крови', 'Кино', 286000),
    ('Город золотой', 'Аквариум', 214000),
    ('Ветер', 'ДДТ', 301000),
    ('Перемен', 'Кино', 296000),
    ('Последний герой', 'Кино', 205000),
    ('Танец на цыпочках', 'Пикник', 247000),
  ];

  final _likes = <String>{'1', '4'};
  final _dislikes = <String>{};
  var _queue = <Map<String, Object?>>[];
  var _pos = 0;
  var _repeat = 'off';
  var _shuffle = false;
  var _wave = false;
  var _loading = false;
  var _quality = 'lossless';
  var _auto = true;
  var _volume = 0.8;
  var _next = 100;
  Map<String, Object?>? _source;
  final List<String> started = [];
  final List<String> failed = [];
  var _failures = 0;
  final List<String> ended = [];
  final List<String> waves = [];

  Map<String, Object?> _track(int i, {String? id}) {
    final (title, artist, ms) = _songs[i % _songs.length];
    final tid = id ?? '${i + 1}';
    return {
      'id': tid,
      'albumId': '9',
      'title': title,
      'artist': artist,
      'artists': [
        {'name': artist, 'source': fakeArtist(artist)},
      ],
      'album': 'Группа крови',
      'albumSource': fakeAlbum,
      'cover': '',
      'durationMs': ms,
      'explicit': i == 2,
      'liked': _likes.contains(tid),
      'disliked': _dislikes.contains(tid),
      if (i == 7) 'unavailable': true,
      'link': 'https://music.yandex.ru/album/9/track/$tid',
      'lyrics': const ['sync', 'text', 'none'][i % 3],
    };
  }

  static Map<String, Object?> _hit(String kind, String title, String artist, String link) => {
    'kind': kind,
    'id': link.split('/').last,
    'title': title,
    'artist': artist,
    'link': link,
  };

  List<Map<String, Object?>> _chart() => [
    for (var i = 0; i < 5; i++)
      {..._track(i, id: 'c${i + 1}'), 'title': 'Хит ${i + 1}', 'artist': 'Чартовый', 'artists': const []},
  ];

  static String _date(int ago) {
    final now = DateTime.now();
    final d = DateTime(now.year, now.month, now.day - ago);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)}';
  }

  static const _historyDays = [
    (0, [0, 1, 2]),
    (1, [3, 4, 0]),
    (4, [5, 6, 7, 1]),
  ];

  List<Map<String, Object?>> _list(String source) => switch (source) {
    'chart' => _chart(),
    'history' => [
      for (final (_, songs) in _historyDays)
        for (final i in songs) _track(i),
    ],
    _ when source.contains('/track/') => [_track(0, id: source.split('/').last)],
    'liked' => [
      for (var i = 0; i < _songs.length; i++)
        if (_likes.contains('${i + 1}')) _track(i),
    ],
    fakeEmptyPlaylist => [],
    _ => [for (var i = 0; i < _songs.length; i++) _track(i)],
  };

  Map<String, Object?> _info(String source) => switch (source) {
    _ when source.contains('/artist/') => {'kind': 'artist', 'id': source, 'title': _artistName(source)},
    _ when source.contains('/album/') && !source.contains('/track/') => {
      'kind': 'album',
      'id': source,
      'title': 'Группа крови',
      'artist': 'Кино',
      'artists': [
        {'name': 'Кино', 'source': fakeArtist('Кино')},
      ],
      'year': 1988,
    },
    _ when source.contains('/track/') => {'kind': 'track', 'id': source, 'title': _songs[0].$1},
    'liked' => {'kind': 'liked', 'id': 'liked', 'title': 'Мне нравится'},
    'chart' => {'kind': 'chart', 'id': 'chart', 'title': 'Чарт'},
    'history' => {'kind': 'history', 'id': 'history', 'title': 'История'},
    fakeEmptyPlaylist => {'kind': 'playlist', 'id': source, 'title': 'Пустой'},
    _ => {'kind': 'playlist', 'id': source, 'title': 'Дорога'},
  };

  String _artistName(String source) {
    for (final (_, artist, _) in _songs) {
      if (source.startsWith(fakeArtist(artist))) return artist;
    }
    return 'Кино';
  }

  Map<String, Object?>? get _current => _pos < _queue.length ? _queue[_pos] : null;

  Map<String, Object?> _fresh(Map<String, Object?> t) => {
    ...t,
    'liked': _likes.contains(t['id']),
    'disliked': _dislikes.contains(t['id']),
  };

  void emitPlayer([String action = '']) {
    final cur = _current;
    final nextPos = _repeat == 'one' ? _pos : _pos + 1;
    final next = nextPos < _queue.length ? _queue[nextPos] : (_repeat == 'all' && _queue.isNotEmpty ? _queue[0] : null);
    _emit({
      'type': 'player',
      if (action.isNotEmpty) 'action': action,
      'track': cur == null ? null : _fresh(cur),
      if (cur != null) 'url': 'fake://track/${cur['id']}?q=$_quality',
      if (next != null) 'next': _fresh(next),
      if (next != null) 'nextUrl': 'fake://track/${next['id']}?q=$_quality',
      'pos': _pos,
      'count': _queue.length,
      'repeat': _repeat,
      'shuffle': _shuffle,
      'wave': _wave,
      'loading': _loading,
      'quality': _quality,
      'autoQuality': _auto,
      'volume': _volume,
      'source': ?_source,
    });
    if (cur != null && (action == 'play' || action == 'resume')) {
      _later(const Duration(milliseconds: 50), () {
        _emit({
          'type': 'playerFormat',
          'track': cur['id'],
          'format': _quality == 'lossless' ? 'FLAC' : (_quality == 'mp3' ? 'MP3 320' : 'MP3 192'),
        });
      });
    }
  }

  void emitQueue() => _emit({
    'type': 'queue',
    'pos': _pos,
    'tracks': [for (final t in _queue) _fresh(t)],
    'source': ?_source,
  });

  void _mark(String id) => _emit({
    'type': 'mark',
    'track': id,
    'liked': _likes.contains(id),
    'disliked': _dislikes.contains(id),
    'likedCount': _likes.length,
  });

  void _startWave(String title) {
    _wave = true;
    _loading = true;
    _queue = [];
    _pos = 0;
    _source = {'kind': 'wave', 'id': 'wave', 'title': title};
    emitPlayer();
    _later(const Duration(milliseconds: 200), () {
      _loading = false;
      _waveMore();
      emitPlayer('play');
      emitQueue();
    });
  }

  void _waveMore() {
    _queue = [
      ..._queue,
      for (var k = 0; k < 3; k++) _track(Random(_next).nextInt(_songs.length - 1), id: '${_next++}'),
    ];
  }

  bool handle(Map<String, Object?> c) {
    final track = c['track'];
    bool stale() => track != null && _current?['id'] != track;
    switch (c['cmd']) {
      case 'home':
        _later(const Duration(milliseconds: 150), () {
          _emit({
            'type': 'home',
            'personal': [
              _hit(
                'playlist',
                'Плейлист дня',
                'Яндекс Музыка',
                'https://music.yandex.ru/users/yamusic-daily/playlists/1',
              ),
              _hit('playlist', 'Дежавю', 'Яндекс Музыка', 'https://music.yandex.ru/users/yamusic-daily/playlists/2'),
            ],
            'history': [
              _hit('album', 'Ночь', 'Кино', 'https://music.yandex.ru/album/77'),
              _hit('artist', 'Наутилус Помпилиус', '', 'https://music.yandex.ru/artist/88'),
              _hit('playlist', 'Вечер', 'Иван Петров', 'https://music.yandex.ru/users/ivan.petrov/playlists/1009'),
            ],
            'releases': [
              for (var i = 1; i <= 6; i++)
                _hit('album', 'Новинка $i', 'Исполнитель $i', 'https://music.yandex.ru/album/${500 + i}'),
            ],
            'playlists': [
              _hit('playlist', 'Свежее', 'Яндекс Музыка', 'https://music.yandex.ru/users/music/playlists/3'),
            ],
            'chart': _chart(),
          });
        });
      case 'library':
        _later(const Duration(milliseconds: 150), () {
          _emit({
            'type': 'library',
            'likedCount': _likes.length,
            'playlists': [
              {'source': fakePlaylist, 'title': 'Дорога', 'owner': 'Иван Петров', 'count': _songs.length},
              {'source': fakeEmptyPlaylist, 'title': 'Пустой', 'owner': 'Иван Петров', 'count': 0},
            ],
            'likedPlaylists': [],
          });
        });
      case 'open':
        final source = '${c['source']}';
        _later(const Duration(milliseconds: 150), () {
          _emit({
            'type': 'tracks',
            'source': source,
            'info': _info(source),
            'tracks': _list(source),
            if (source == 'history')
              'days': [
                for (final (ago, songs) in _historyDays) {'date': _date(ago), 'count': songs.length},
              ],
            if (source.contains('/artist/') && !source.endsWith('/tracks'))
              'albums': [
                {'source': 'https://music.yandex.ru/album/10', 'title': 'Группа крови', 'year': 1988, 'count': 8},
                {
                  'source': 'https://music.yandex.ru/album/11',
                  'title': 'Звезда по имени Солнце',
                  'year': 1989,
                  'count': 10,
                  'type': 'album',
                },
                {
                  'source': 'https://music.yandex.ru/album/13',
                  'title': 'Чёрный альбом',
                  'year': 1990,
                  'count': 10,
                  'type': 'album',
                  'explicit': true,
                },
                {
                  'source': 'https://music.yandex.ru/album/12',
                  'title': 'Кукушка',
                  'year': 1990,
                  'count': 1,
                  'type': 'single',
                },
                {
                  'source': 'https://music.yandex.ru/album/14',
                  'title': 'Последний герой',
                  'year': 1989,
                  'count': 14,
                  'type': 'compilation',
                },
              ],
          });
        });
      case 'wave':
        final title = '${c['title'] ?? ''}';
        waves.add('${c['source'] ?? c['track']}');
        _startWave(title.isEmpty ? 'Моя волна' : 'Моя волна: $title');
      case 'play':
        final source = '${c['source']}';
        if (source == 'wave') {
          _startWave('Моя волна');
          return true;
        }
        _wave = false;
        _loading = false;
        _source = _info(source);
        final all = _list(source);
        _queue = [
          for (final t in all)
            if (t['unavailable'] != true) t,
        ];
        if (_queue.isEmpty) return true;
        final i = _queue.indexWhere((t) => t['id'] == track);
        final index = (c['index'] as int?) ?? 0;
        final exact =
            index >= 0 && index < all.length && all[index]['id'] == track && all[index]['unavailable'] != true;
        _pos = exact
            ? all.take(index).where((t) => t['unavailable'] != true).length
            : (i >= 0 ? i : index.clamp(0, _queue.length - 1));
        if (_shuffle) {
          final cur = _queue.removeAt(_pos);
          _queue = [cur, ..._queue.reversed];
          _pos = 0;
        }
        emitPlayer('play');
        emitQueue();
      case 'lyrics':
        final id = '$track';
        final known = [..._queue, for (var i = 0; i < _songs.length; i++) _track(i)];
        final kind = known.firstWhere((t) => t['id'] == id, orElse: () => const {})['lyrics'];
        _later(const Duration(milliseconds: 100), () {
          _emit({
            'type': 'lyrics',
            'track': id,
            'synced': kind == 'sync',
            'lines': switch (kind) {
              'sync' => [for (var n = 0; n < 12; n++) {'ms': n * 15000, 'text': n % 4 == 3 ? '' : 'Строка ${n + 1}'}],
              'text' => [for (var n = 0; n < 8; n++) {'ms': -1, 'text': 'Строка ${n + 1}'}],
              _ => const [],
            },
            if (kind != 'none') 'writers': ['Автор песни'],
          });
        });
      case 'playerStarted':
        started.add('$track');
        _failures = 0;
      case 'playerError':
        if (stale()) return true;
        failed.add('$track');
        if (++_failures >= 3) {
          _failures = 0;
          _emit({'type': 'notice', 'kind': 'error', 'message': 'Не удаётся воспроизвести треки'});
          emitPlayer('end');
        } else if (_pos + 1 < _queue.length) {
          _pos++;
          emitPlayer('play');
        } else {
          emitPlayer('end');
        }
      case 'playerEnded' || 'playerNext':
        if (stale()) return true;
        if (c['cmd'] == 'playerEnded') ended.add('$track');
        final auto = c['cmd'] == 'playerEnded';
        if (auto && _repeat == 'one') {
          emitPlayer('play');
        } else if (_pos + 1 < _queue.length) {
          _pos++;
          emitPlayer('play');
        } else if (_wave) {
          _waveMore();
          _pos++;
          emitPlayer('play');
          emitQueue();
        } else if (_repeat == 'all') {
          _pos = 0;
          emitPlayer('play');
        } else {
          emitPlayer('end');
        }
        if (_wave && _queue.length - _pos < 2) {
          _waveMore();
          emitQueue();
        }
      case 'playerPrev':
        if (stale()) return true;
        if (((c['position'] as num?) ?? 0) <= 3 && _pos > 0) _pos--;
        emitPlayer('play');
      case 'playerJump':
        final to = (c['pos'] as int?) ?? 0;
        if (to < 0 || to >= _queue.length) return true;
        _pos = to;
        emitPlayer('play');
      case 'playerRepeat':
        _repeat = '${c['repeat']}';
        if (_wave && _repeat == 'all') _repeat = 'off';
        emitPlayer();
      case 'playerShuffle':
        _shuffle = c['on'] == true;
        emitPlayer();
      case 'playerQuality':
        _auto = c['quality'] == 'auto';
        _quality = _auto ? 'lossless' : '${c['quality']}';
        emitPlayer('resume');
      case 'playerVolume':
        _volume = ((c['volume'] as num?) ?? _volume).toDouble();
      case 'playerState':
        emitPlayer();
      case 'queue':
        emitQueue();
      case 'like':
        final id = '$track';
        c['on'] == true ? _likes.add(id) : _likes.remove(id);
        if (c['on'] == true) _dislikes.remove(id);
        _mark(id);
        emitPlayer();
      case 'dislike':
        final id = '$track';
        c['on'] == true ? _dislikes.add(id) : _dislikes.remove(id);
        if (c['on'] == true) _likes.remove(id);
        _mark(id);
        if (c['on'] == true && _current?['id'] == id) {
          if (_pos + 1 >= _queue.length) _waveMore();
          _pos++;
          emitPlayer('play');
          emitQueue();
        } else {
          emitPlayer();
        }
      case 'logout':
        _queue = [];
        _pos = 0;
        _source = null;
        _wave = false;
        emitPlayer('stop');
        return false;
      default:
        return false;
    }
    return true;
  }
}
