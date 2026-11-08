import 'dart:async';

import 'core.dart';
import 'fake_player.dart';
import 'fake_remote.dart';

class FakeCore implements Core {
  FakeCore({this.tick = const Duration(milliseconds: 120), this.latest = '0.2.1'});

  final Duration tick;
  final String latest;
  final _events = StreamController<Event>();
  final _timers = <Timer>{};
  final _jobs = <int, _FakeJob>{};
  var _nextId = 0;
  Timer? _ticker;

  var _dir = r'C:\Users\user\Music\Yandex Music Downloads';
  var _theme = 'dark';
  var _quality = 'lossless';
  var _concurrency = 4;
  var _plus = false;
  var _deviceSeq = 0;
  Map<String, Object?>? lastDownload;
  late final player = FakePlayer(_emit, _later);
  late final remote = FakeRemote(_emit, _later);

  static const _albums = [
    {'id': '10', 'title': 'Группа крови', 'year': 1988, 'count': 11, 'type': 'album'},
    {'id': '11', 'title': 'Звезда по имени Солнце', 'year': 1989, 'count': 10, 'type': 'album'},
    {'id': '12', 'title': 'Кукушка', 'year': 1990, 'count': 1, 'type': 'single'},
    {'id': '13', 'title': 'Последний герой', 'year': 1989, 'count': 11, 'type': 'compilation'},
  ];

  @override
  Stream<Event> get events => _events.stream;

  void _emit(Event e) {
    if (!_events.isClosed) scheduleMicrotask(() => _events.add(e));
  }

  void _later(Duration d, void Function() f) {
    late final Timer t;
    t = Timer(d, () {
      _timers.remove(t);
      f();
    });
    _timers.add(t);
  }

  Map<String, Object?> _state() => {
        'type': 'state',
        'dir': _dir,
        'theme': _theme,
        'quality': _quality,
        'concurrency': _concurrency,
        'version': '0.2.1',
        'playAuto': _playAuto,
        'playManual': _playManual,
        'playWifi': _playWifi,
        'playMobile': _playMobile,
        'playQuality': _playAuto ? _playWifi : _playManual,
        'crossfade': _crossfade,
        'fade': _fade,
      };

  var _crossfade = true;
  var _fade = 6;

  var _playAuto = true;
  var _playManual = 'lossless';
  var _playWifi = 'lossless';
  var _playMobile = 'mp3';
  final List<Map<String, Object?>> playQuality = [];

  @override
  void send(Map<String, Object?> c) {
    if (player.handle(c) || remote.handle(c)) return;
    switch (c['cmd']) {
      case 'ready':
        _emit(_state());
        _emit({'type': 'account', 'status': 'none'});
        player.emitPlayer();
        if (latest != '0.2.1') _emit({..._update(), 'quiet': true});
      case 'checkUpdate':
        _later(tick, () => _emit(_update()));
      case 'applyUpdate':
        for (var i = 0; i <= 4; i++) {
          _later(tick * i, () => _emit({'type': 'updating', 'done': i * 5, 'total': 20}));
        }
      case 'login':
        final token = '${c['token']}';
        _emit({'type': 'account', 'status': 'checking'});
        _later(const Duration(milliseconds: 500), () {
          _plus = token != 'bad' && token != 'noplus';
          _emit(switch (token) {
            'bad' => {
                'type': 'account',
                'status': 'error',
                'message': 'токен недействителен или устарел, получите новый',
              },
            'noplus' => {
                'type': 'account',
                'status': 'noplus',
                'login': 'ivan.petrov',
                'name': 'Иван Петров',
                'hasPlus': false,
                'message': 'для скачивания нужна активная подписка Яндекс Плюс',
              },
            _ => {
                'type': 'account',
                'status': 'ok',
                'login': 'ivan.petrov',
                'name': 'Иван Петров',
                'hasPlus': true,
              },
          });
        });
      case 'deviceLogin':
        final seq = ++_deviceSeq;
        _later(tick, () {
          if (seq != _deviceSeq) return;
          _emit({
            'type': 'deviceLogin',
            'status': 'code',
            'code': 'abcd1234',
            'url': 'https://ya.ru/device',
            'expiresIn': 300,
          });
        });
        _later(tick * 25, () {
          if (seq != _deviceSeq) return;
          _plus = true;
          _emit({'type': 'deviceLogin', 'status': 'done'});
          _emit({'type': 'account', 'status': 'checking'});
          _later(const Duration(milliseconds: 500), () {
            _emit({
              'type': 'account',
              'status': 'ok',
              'login': 'ivan.petrov',
              'name': 'Иван Петров',
              'hasPlus': true,
            });
          });
        });
      case 'deviceCancel':
        _deviceSeq++;
      case 'recheck' when _plus:
        _later(const Duration(milliseconds: 300), () {
          _emit({
            'type': 'account',
            'status': 'ok',
            'login': 'ivan.petrov',
            'name': 'Иван Петров',
            'hasPlus': true
          });
          _emit({'type': 'notice', 'kind': 'ok', 'message': 'Подписка Плюс активна'});
        });
      case 'recheck':
        _emit({'type': 'account', 'status': 'checking', 'login': 'ivan.petrov'});
        _later(const Duration(milliseconds: 400), () {
          _emit({
            'type': 'account',
            'status': 'ok',
            'login': 'ivan.petrov',
            'name': 'Иван Петров',
            'hasPlus': true
          });
        });
      case 'logout':
        _plus = false;
        for (final j in _jobs.values) {
          j.cancelled = true;
        }
        _emit({'type': 'account', 'status': 'none'});
      case 'prefs':
        if (c['dir'] case final String d when d.isNotEmpty) _dir = d;
        if (c['theme'] case final String t when t.isNotEmpty) _theme = t;
        if (c['quality'] case final String q when q.isNotEmpty) _quality = q;
        if (c['concurrency'] case final int n when n > 0) _concurrency = n;
        if (c['crossfade'] case final bool on) _crossfade = on;
        if (c['fade'] case final int n when n > 0) _fade = n;
        _emit(_state());
      case 'playQuality':
        playQuality.add(c);
        if (c['auto'] case final bool a) _playAuto = a;
        if (c['quality'] case final String q when q.isNotEmpty) _playManual = q;
        if (c['wifi'] case final String q when q.isNotEmpty) _playWifi = q;
        if (c['mobile'] case final String q when q.isNotEmpty) _playMobile = q;
        _emit(_state());
      case 'download':
        lastDownload = c;
        _download('${c['link']}');
      case 'search':
        _search(c);
      case 'cancel':
        final id = c['id'] as int? ?? 0;
        for (final j in _jobs.values) {
          if (id == 0 || j.id == id) j.cancelled = true;
        }
      case 'retry':
        final j = _jobs.remove(c['id']);
        if (j != null) {
          _emit({'type': 'jobRemoved', 'id': j.id});
          _download(j.link);
        }
      case 'remove':
        final id = c['id'] as int? ?? 0;
        _jobs.removeWhere((k, j) {
          final drop = (id == 0 || k == id) && j.finished;
          if (drop) _emit({'type': 'jobRemoved', 'id': k});
          return drop;
        });
      case 'exit':
        _emit({'type': 'exit'});
    }
  }

  Map<String, Object?> _update() => {
        'type': 'update',
        'current': '0.2.1',
        'latest': latest,
        'page': 'https://github.com/TheGreatPepix/YAMP/releases/tag/v$latest',
        'notes': latest == '0.2.1' ? '' : 'Самообновление из релизов GitHub.',
        'published': '02.11.2026',
        'available': latest != '0.2.1',
        'canApply': latest != '0.2.1',
      };

  static (String, String, String, int, int) _release(String link) {
    if (link == 'liked') return ('playlist', 'Мне нравится', 'Иван Петров', 0, 6);
    if (link.contains('/artist/')) return ('artist', 'Кино', 'Кино', 0, 12);
    if (link.contains('/playlists/')) return ('playlist', 'Плейлист дня', 'Иван Петров', 0, 6);
    if (link.contains('/track/')) return ('track', 'Кукушка', 'Кино', 1990, 1);
    return ('album', 'Группа крови', 'Кино', 1988, 8);
  }

  static const _titles = [
    'Группа крови',
    'Закрой за мной дверь, я ухожу',
    'Война',
    'Спокойная ночь',
    'Мама, мы все тяжело больны',
    'Кукушка',
    'Звезда по имени Солнце',
    'Пачка сигарет',
    'Хочу перемен!',
    'Апрельская',
    'Легенда',
    'Печаль',
  ];

  static const _web = 'https://music.yandex.ru';

  static Map<String, Object?> _hit(String kind, int i) => switch (kind) {
        'track' => {
            'kind': 'track',
            'id': '${500 + i}',
            'title': _titles[i % _titles.length],
            'artist': 'Кино',
            'album': _albums[i % _albums.length]['title'],
            'year': 1988,
            'duration': 180 + i * 7,
            'explicit': i == 1,
            'link': '$_web/album/1/track/${500 + i}',
          },
        'album' => {
            'kind': 'album',
            'id': '${10 + i}',
            'title': '${_albums[i % _albums.length]['title']}${i < _albums.length ? '' : ' $i'}',
            'artist': 'Кино',
            'year': 1988 + i,
            'count': 8,
            'type': _albums[i % _albums.length]['type'],
            'link': '$_web/album/${10 + i}',
          },
        'artist' => {
            'kind': 'artist',
            'id': '${1 + i}',
            'title': i == 0 ? 'Кино' : 'Кино $i',
            'count': 146 - i,
            'link': '$_web/artist/${1 + i}',
          },
        _ => {
            'kind': 'playlist',
            'id': 'me/${3 + i}',
            'title': i == 0 ? 'Плейлист дня' : 'Плейлист $i',
            'artist': 'Яндекс Музыка',
            'count': 6,
            'link': '$_web/users/me/playlists/${3 + i}',
          },
      };

  void _search(Map<String, Object?> c) {
    final query = '${c['query']}';
    final kind = '${c['kind'] ?? ''}';
    final page = c['page'] as int? ?? 0;
    final event = <String, Object?>{
      'type': 'search',
      'seq': c['seq'],
      'query': query,
      'kind': kind,
      'page': page,
    };
    _later(const Duration(milliseconds: 200), () {
      if (query == 'ошибка') {
        _emit({...event, 'status': 'error', 'message': 'нет связи'});
        return;
      }
      if (query == 'пусто') {
        _emit({...event, 'status': 'ok', 'sections': {}});
        return;
      }
      const totals = {'track': 25, 'album': 12, 'artist': 3, 'playlist': 4};
      const perAll = {'track': 20, 'album': 10, 'artist': 10, 'playlist': 4};
      Map<String, Object?> section(String k, int per) {
        final total = totals[k]!;
        final from = page * per;
        return {
          'total': total,
          'more': from + per < total,
          'hits': [for (var i = from; i < total && i < from + per; i++) _hit(k, i)],
        };
      }

      _emit({
        ...event,
        'status': 'ok',
        if (query == 'кина') 'corrected': 'кино',
        if (kind.isEmpty) 'best': _hit('artist', 0),
        'sections': kind.isEmpty
            ? {for (final k in totals.keys) k: section(k, perAll[k]!)}
            : {kind: section(kind, 10)},
      });
    });
  }

  void _download(String link) {
    final (kind, title, artist, year, count) = _release(link);
    final j = _FakeJob(++_nextId, link, kind, title, artist, year, count);
    _jobs[j.id] = j;
    _emit(j.event());
    _later(const Duration(milliseconds: 300), () {
      j.status = 'running';
      j.tracks = [
        for (var i = 0; i < count; i++)
          {
            'i': i,
            'title': _titles[i % _titles.length],
            'artist': artist,
            'status': 'queued',
            'done': 0,
            'size': 28000000 + i * 3100000,
          },
      ];
      _emit(j.event(full: true));
      _ticker ??= Timer.periodic(tick, (_) => _step());
    });
  }

  void _step() {
    var active = 0, queued = 0;
    var speed = 0.0;
    final running = _jobs.values.where((j) => !j.finished).toList();
    var slots = _concurrency;
    for (final j in running) {
      if (j.cancelled) {
        for (final t in j.tracks) {
          if (t['status'] == 'queued' || t['status'] == 'active') t['status'] = 'cancelled';
        }
        j.status = 'cancelled';
        j.message = 'Остановлено';
        _emit(j.event(full: true));
        continue;
      }
      for (final t in j.tracks) {
        if (t['status'] == 'active' || (t['status'] == 'queued' && slots > 0)) {
          if (slots <= 0) break;
          slots--;
          t['status'] = 'active';
          final size = t['size'] as int;
          final done = ((t['done'] as int) + 6000000).clamp(0, size);
          t['done'] = done;
          speed += 6000000 * 1000 / tick.inMilliseconds;
          if (done >= size) {
            t['status'] = 'done';
            t['format'] = (t['i'] as int).isEven ? 'FLAC 24/96' : 'FLAC 16/44.1';
          }
        }
      }
      active += j.tracks.where((t) => t['status'] == 'active').length;
      queued += j.tracks.where((t) => t['status'] == 'queued').length;
      if (j.tracks.every((t) => t['status'] == 'done')) {
        j.status = 'done';
        j.message = 'Скачано ${j.tracks.length}';
        _emit({'type': 'notice', 'kind': 'ok', 'message': '${j.title}: ${j.message}'});
      }
      _emit(j.event(full: true));
    }
    _emit({'type': 'stats', 'speed': speed, 'active': active, 'queued': queued});
    if (_jobs.values.every((j) => j.finished)) {
      _ticker?.cancel();
      _ticker = null;
      _emit({'type': 'stats', 'speed': 0, 'active': 0, 'queued': 0});
    }
  }

  @override
  Future<void> close() async {
    _ticker?.cancel();
    for (final t in _timers) {
      t.cancel();
    }
    _timers.clear();
    await _events.close();
  }
}

class _FakeJob {
  _FakeJob(this.id, this.link, this.kind, this.title, this.artist, this.year, this.count);

  final int id, year, count;
  final String link, kind, title, artist;
  var status = 'resolving';
  var message = '';
  var cancelled = false;
  List<Map<String, Object?>> tracks = [];

  bool get finished => status == 'done' || status == 'error' || status == 'cancelled';

  Event event({bool full = false}) => {
        'type': 'job',
        'id': id,
        'link': link,
        'kind': kind,
        'title': status == 'resolving' ? '' : title,
        'artist': artist,
        'year': year,
        'cover': '',
        'dir': r'C:\Users\user\Music\Yandex Music Downloads',
        'status': status,
        'message': message,
        'total': tracks.length,
        'full': full,
        'tracks': full ? tracks.map(Map.of).toList() : const [],
      };
}
