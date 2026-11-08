import 'dart:async';

import 'package:flutter/foundation.dart';

import '../player/engine.dart';
import 'search.dart';

enum Repeat { off, all, one }

enum PlayQuality { lossless, mp3, low }

enum LoadStatus { idle, loading, ok, error }

const sourceWave = 'wave';
const sourceLiked = 'liked';
const sourceHome = 'home';
const sourceChart = 'chart';
const sourceHistory = 'history';

String topTracksOf(String artist) => '$artist/tracks';

bool isTopTracks(String source) => source.contains('/artist/') && source.endsWith('/tracks');

String artistOfTop(String source) =>
    isTopTracks(source) ? source.substring(0, source.length - '/tracks'.length) : source;

String _s(Object? v) => v == null ? '' : '$v';

int _i(Object? v) => (v as num?)?.toInt() ?? 0;

class PlayArtist {
  const PlayArtist({required this.name, required this.source});

  factory PlayArtist.fromJson(Map<String, dynamic> j) => PlayArtist(name: _s(j['name']), source: _s(j['source']));

  final String name, source;
}

List<PlayArtist> _artists(Object? v) => [
  for (final a in (v as List? ?? const []))
    if (a is Map<String, dynamic>) PlayArtist.fromJson(a),
];

class PlayTrack {
  const PlayTrack({
    required this.id,
    this.albumId = '',
    this.title = '',
    this.artist = '',
    this.artists = const [],
    this.album = '',
    this.albumSource = '',
    this.cover = '',
    this.durationMs = 0,
    this.explicit = false,
    this.liked = false,
    this.disliked = false,
    this.unavailable = false,
    this.link = '',
    this.lyrics = '',
  });

  factory PlayTrack.fromJson(Map<String, dynamic> j) => PlayTrack(
    id: _s(j['id']),
    albumId: _s(j['albumId']),
    title: _s(j['title']),
    artist: _s(j['artist']),
    artists: _artists(j['artists']),
    album: _s(j['album']),
    albumSource: _s(j['albumSource']),
    cover: _s(j['cover']),
    durationMs: _i(j['durationMs']),
    explicit: j['explicit'] == true,
    liked: j['liked'] == true,
    disliked: j['disliked'] == true,
    unavailable: j['unavailable'] == true,
    link: _s(j['link']),
    lyrics: _s(j['lyrics']),
  );

  final String id, albumId, title, artist, album, albumSource, cover, link, lyrics;
  final List<PlayArtist> artists;
  final int durationMs;
  final bool explicit, liked, disliked, unavailable;

  Duration get duration => Duration(milliseconds: durationMs);

  bool get hasLyrics => lyrics != 'none';
}

class LyricLine {
  const LyricLine(this.at, this.text);

  final Duration? at;
  final String text;
}

class Lyrics {
  const Lyrics({
    this.status = LoadStatus.loading,
    this.synced = false,
    this.lines = const [],
    this.writers = const [],
    this.error = '',
  });

  final LoadStatus status;
  final bool synced;
  final List<LyricLine> lines;
  final List<String> writers;
  final String error;

  int lineAt(Duration position) {
    if (!synced) return -1;
    var lo = 0, hi = lines.length - 1, found = -1;
    while (lo <= hi) {
      final mid = (lo + hi) ~/ 2;
      if (lines[mid].at! <= position) {
        found = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return found;
  }
}

class PlaySource {
  const PlaySource({
    required this.kind,
    required this.id,
    this.title = '',
    this.cover = '',
    this.artist = '',
    this.artists = const [],
    this.year = 0,
  });

  factory PlaySource.fromJson(Map<String, dynamic> j) => PlaySource(
    kind: _s(j['kind']),
    id: _s(j['id']),
    title: _s(j['title']),
    cover: _s(j['cover']),
    artist: _s(j['artist']),
    artists: _artists(j['artists']),
    year: _i(j['year']),
  );

  final String kind, id, title, cover, artist;
  final List<PlayArtist> artists;
  final int year;

  bool get browsable => kind != sourceWave && id.isNotEmpty;
}

class SourceAlbum {
  const SourceAlbum({
    required this.source,
    required this.title,
    this.year = 0,
    this.cover = '',
    this.count = 0,
    this.type = 'album',
    this.explicit = false,
  });

  factory SourceAlbum.fromJson(Map<String, dynamic> j) => SourceAlbum(
    source: _s(j['source']),
    title: _s(j['title']),
    year: _i(j['year']),
    cover: _s(j['cover']),
    count: _i(j['count']),
    type: _s(j['type']).isEmpty ? 'album' : _s(j['type']),
    explicit: j['explicit'] == true,
  );

  final String source, title, cover, type;
  final int year, count;
  final bool explicit;
}

class LibraryPlaylist {
  const LibraryPlaylist({required this.source, required this.title, this.owner = '', this.count = 0, this.cover = ''});

  factory LibraryPlaylist.fromJson(Map<String, dynamic> j) => LibraryPlaylist(
    source: _s(j['source']),
    title: _s(j['title']),
    owner: _s(j['owner']),
    count: _i(j['count']),
    cover: _s(j['cover']),
  );

  final String source, title, owner, cover;
  final int count;
}

class HomeFeed {
  const HomeFeed({
    this.status = LoadStatus.idle,
    this.personal = const [],
    this.history = const [],
    this.releases = const [],
    this.playlists = const [],
    this.chart = const [],
    this.error = '',
  });

  final LoadStatus status;
  final List<SearchHit> personal, history, releases, playlists;
  final List<PlayTrack> chart;
  final String error;
}

List<SearchHit> _hits(Object? v) => [
  for (final h in (v as List? ?? const []))
    if (h is Map<String, dynamic>) SearchHit.fromJson(h),
];

class Library {
  const Library({
    this.status = LoadStatus.idle,
    this.playlists = const [],
    this.likedPlaylists = const [],
    this.likedCount = 0,
    this.error = '',
  });

  final LoadStatus status;
  final List<LibraryPlaylist> playlists, likedPlaylists;
  final int likedCount;
  final String error;
}

class HistoryDay {
  const HistoryDay({required this.date, required this.count});

  factory HistoryDay.fromJson(Map<String, dynamic> j) => HistoryDay(date: _s(j['date']), count: _i(j['count']));

  final String date;
  final int count;
}

class TrackList {
  const TrackList({
    this.status = LoadStatus.loading,
    this.info,
    this.tracks = const [],
    this.albums = const [],
    this.days = const [],
    this.error = '',
  });

  final LoadStatus status;
  final PlaySource? info;
  final List<PlayTrack> tracks;
  final List<SourceAlbum> albums;
  final List<HistoryDay> days;
  final String error;

  Duration get total => tracks.fold(Duration.zero, (sum, t) => sum + t.duration);
}

List<PlayTrack> _tracks(Object? v) => [
  for (final t in (v as List? ?? const []))
    if (t is Map<String, dynamic>) PlayTrack.fromJson(t),
];

class PlayerState extends ChangeNotifier {
  PlayerState(this._send, this.engine) {
    _subs = [
      engine.position.listen(_onPosition),
      engine.duration.listen((d) {
        if (d > Duration.zero) duration.value = d;
      }),
      engine.playing.listen(_onPlaying),
      engine.buffering.listen(_onBuffering),
      engine.completed.listen((_) => _onCompleted()),
      engine.errors.listen(_onError),
    ];
  }

  final void Function(Map<String, Object?>) _send;
  final AudioEngine engine;
  late final List<StreamSubscription<Object?>> _subs;

  PlayTrack? track;
  PlayTrack? next;
  var art = '';
  var url = '';
  var nextUrl = '';
  var crossfade = Duration.zero;
  var pos = 0;
  var count = 0;
  var repeat = Repeat.off;
  var shuffle = false;
  var wave = false;
  var loading = false;
  var offline = false;
  var quality = PlayQuality.lossless;
  var autoQuality = false;
  var volume = 0.8;
  PlaySource? source;
  var format = '';
  var queue = const <PlayTrack>[];

  var _engineOn = false;
  var _advancing = false;
  var _userPaused = false;
  String? _handoff;
  var buffering = false;
  Timer? _bufferTimer;

  static const _bufferShowAfter = Duration(milliseconds: 500);
  static const _endSlack = Duration(milliseconds: 1500);

  bool get playing => _engineOn || _advancing;
  final position = ValueNotifier(Duration.zero);
  final duration = ValueNotifier(Duration.zero);

  final panelOpen = ValueNotifier(false);
  final lyricsOpen = ValueNotifier(false);
  final lyrics = <String, Lyrics>{};
  final browse = ValueNotifier(sourceHome);
  final browsing = ValueNotifier(false);
  final _history = <String>[];

  bool get canBack => _history.isNotEmpty;

  void browseTo(String source, {bool fromLibrary = false}) {
    if (fromLibrary) _history.clear();
    if (browse.value != source) {
      if (!fromLibrary) _history.add(browse.value);
      browse.value = source;
    }
    browsing.value = true;
    openList(source);
  }

  void back() {
    if (_history.isEmpty) {
      browsing.value = false;
      return;
    }
    browse.value = _history.removeLast();
    if (browse.value == sourceHome) {
      browsing.value = false;
      return;
    }
    openList(browse.value);
  }

  var library = const Library();
  var home = const HomeFeed();
  final lists = <String, TrackList>{};
  final _marks = <String, (bool, bool)>{};
  var likedCount = 0;

  String? _startedFor;
  String? _announced;
  Duration? _pending;
  var _reported = Duration.zero;
  String? _failedFor;
  var _openedAt = Duration.zero;
  var _volumeApplied = false;

  bool get hasTrack => track != null;

  bool liked(PlayTrack t) => _marks[t.id]?.$1 ?? t.liked;

  bool disliked(PlayTrack t) => _marks[t.id]?.$2 ?? t.disliked;

  bool isCurrent(PlayTrack t) => track?.id == t.id;

  bool get playingWave => wave && hasTrack;

  void receive(Map<String, dynamic> ev) {
    switch (ev['type']) {
      case 'player':
        _onPlayer(ev);
      case 'queue':
        queue = _tracks(ev['tracks']);
        pos = _i(ev['pos']);
      case 'playerFormat':
        if (ev['track'] != track?.id) return;
        format = _s(ev['format']);
      case 'mark':
        _marks[_s(ev['track'])] = (ev['liked'] == true, ev['disliked'] == true);
        likedCount = _i(ev['likedCount']);
        if (lists.containsKey(sourceLiked)) _send({'cmd': 'open', 'source': sourceLiked});
      case 'home':
        final error = _s(ev['error']);
        home = error.isNotEmpty
            ? HomeFeed(status: LoadStatus.error, error: error)
            : HomeFeed(
                status: LoadStatus.ok,
                personal: _hits(ev['personal']),
                history: _hits(ev['history']),
                releases: _hits(ev['releases']),
                playlists: _hits(ev['playlists']),
                chart: _tracks(ev['chart']),
              );
      case 'library':
        final error = _s(ev['error']);
        likedCount = _i(ev['likedCount']);
        library = error.isNotEmpty
            ? Library(status: LoadStatus.error, error: error)
            : Library(
                status: LoadStatus.ok,
                likedCount: likedCount,
                playlists: [
                  for (final p in (ev['playlists'] as List? ?? const []))
                    if (p is Map<String, dynamic>) LibraryPlaylist.fromJson(p),
                ],
                likedPlaylists: [
                  for (final p in (ev['likedPlaylists'] as List? ?? const []))
                    if (p is Map<String, dynamic>) LibraryPlaylist.fromJson(p),
                ],
              );
      case 'lyrics':
        final id = _s(ev['track']);
        final error = _s(ev['error']);
        if (lyrics.length > 40) lyrics.remove(lyrics.keys.first);
        final synced = ev['synced'] == true;
        lyrics[id] = error.isNotEmpty
            ? Lyrics(status: LoadStatus.error, error: error)
            : Lyrics(
                status: LoadStatus.ok,
                synced: synced,
                lines: [
                  for (final l in (ev['lines'] as List? ?? const []))
                    if (l is Map<String, dynamic>)
                      LyricLine(synced ? Duration(milliseconds: _i(l['ms'])) : null, _s(l['text'])),
                ],
                writers: [for (final w in (ev['writers'] as List? ?? const [])) _s(w)],
              );
      case 'tracks':
        final source = _s(ev['source']);
        final error = _s(ev['error']);
        final info = ev['info'];
        lists[source] = error.isNotEmpty
            ? TrackList(status: LoadStatus.error, error: error)
            : TrackList(
                status: LoadStatus.ok,
                info: info is Map<String, dynamic> ? PlaySource.fromJson(info) : null,
                tracks: _tracks(ev['tracks']),
                albums: [
                  for (final a in (ev['albums'] as List? ?? const []))
                    if (a is Map<String, dynamic>) SourceAlbum.fromJson(a),
                ],
                days: [
                  for (final d in (ev['days'] as List? ?? const []))
                    if (d is Map<String, dynamic>) HistoryDay.fromJson(d),
                ],
              );
      default:
        return;
    }
    notifyListeners();
  }

  void _onPlayer(Map<String, dynamic> ev) {
    final t = ev['track'];
    final n = ev['next'];
    final previous = track?.id;
    track = t is Map<String, dynamic> ? PlayTrack.fromJson(t) : null;
    next = n is Map<String, dynamic> ? PlayTrack.fromJson(n) : null;
    art = _s(ev['art']);
    url = _s(ev['url']);
    nextUrl = _s(ev['nextUrl']);
    pos = _i(ev['pos']);
    count = _i(ev['count']);
    repeat = Repeat.values.asNameMap()[_s(ev['repeat'])] ?? Repeat.off;
    shuffle = ev['shuffle'] == true;
    wave = ev['wave'] == true;
    loading = ev['loading'] == true;
    offline = ev['offline'] == true;
    quality = PlayQuality.values.asNameMap()[_s(ev['quality'])] ?? PlayQuality.lossless;
    autoQuality = ev['autoQuality'] == true;
    volume = (ev['volume'] as num?)?.toDouble() ?? volume;
    final s = ev['source'];
    source = s is Map<String, dynamic> ? PlaySource.fromJson(s) : null;
    if (track?.id != previous) format = '';
    if (!_volumeApplied) {
      _volumeApplied = true;
      engine.setVolume(volume);
    }

    final current = track;
    if (const {'play', 'resume', 'retry', 'stop', 'restore'}.contains(ev['action'])) _pending = null;
    if (const {'play', 'resume', 'retry', 'stop', 'restore', 'end'}.contains(ev['action'])) _handoff = null;
    switch (ev['action']) {
      case 'play' when current != null:
        _startedFor = null;
        _announced = null;
        _failedFor = null;
        _openedAt = Duration.zero;
        position.value = Duration.zero;
        duration.value = current.duration;
        engine.open(url, hint: current.duration);
      case 'resume' when current != null:
        _failedFor = null;
        _openedAt = position.value;
        engine.open(url, start: position.value, play: playing, hint: current.duration);
      case 'restore' when current != null:
        final at = Duration(milliseconds: (((ev['start'] as num?) ?? 0) * 1000).round());
        _startedFor = null;
        _announced = null;
        _failedFor = null;
        _pending = at;
        _reported = at;
        position.value = at;
        duration.value = current.duration;
      case 'retry' when current != null:
        final at = Duration(milliseconds: (((ev['start'] as num?) ?? 0) * 1000).round());
        _startedFor = null;
        _failedFor = null;
        _openedAt = at;
        position.value = at;
        engine.open(url, start: at, hint: current.duration);
      case 'stop':
        _startedFor = null;
        _announced = null;
        position.value = Duration.zero;
        duration.value = Duration.zero;
        _settleAdvance();
        engine.stop();
      case 'end':
        _settleAdvance();
        engine.pause();
    }
  }

  void _onPlaying(bool v) {
    if (_engineOn == v) return;
    final was = playing;
    _engineOn = v;
    if (v) {
      _advancing = false;
      _userPaused = false;
    } else if (!_userPaused && track != null && _nearEnd) {
      _advancing = true;
    }
    if (!v && !_advancing) savePosition();
    if (playing == was) return;
    if (playing) _reportPlayback();
    notifyListeners();
  }

  bool get _nearEnd {
    final total = duration.value;
    return total > Duration.zero && total - position.value < _endSlack;
  }

  void _settleAdvance() {
    if (!_advancing) return;
    _advancing = false;
    if (!_engineOn) notifyListeners();
  }

  void _onBuffering(bool b) {
    _bufferTimer?.cancel();
    _bufferTimer = null;
    if (!b) {
      if (!buffering) return;
      buffering = false;
      notifyListeners();
      return;
    }
    if (buffering) return;
    _bufferTimer = Timer(_bufferShowAfter, () {
      _bufferTimer = null;
      buffering = true;
      notifyListeners();
    });
  }

  static const _reportEvery = Duration(seconds: 10);

  void savePosition() {
    final id = track?.id;
    if (id == null || _pending != null) return;
    _reported = position.value;
    _send({'cmd': 'playerPosition', 'track': id, 'position': _seconds, 'playing': playing, 'on': true});
  }

  void _reportPlayback() {
    final id = track?.id;
    if (id == null || _pending != null) return;
    _reported = position.value;
    _send({'cmd': 'playerPosition', 'track': id, 'position': _seconds, 'playing': playing});
  }

  void _onPosition(Duration p) {
    position.value = p;
    final id = track?.id;
    if (id != null && playing && (p - _reported).abs() >= _reportEvery) {
      _reported = p;
      _send({'cmd': 'playerPosition', 'track': id, 'position': _seconds, 'playing': playing});
    }
    _crossfade(p);
    if (id == null || _startedFor == id) return;
    if (p > _openedAt && p < _openedAt + const Duration(seconds: 3)) {
      _startedFor = id;
      if (_announced == id) return;
      _announced = id;
      _send({'cmd': 'playerStarted', 'track': id});
    }
  }

  static const _preloadAhead = Duration(seconds: 20);
  static const _shortestFade = Duration(milliseconds: 500);

  void _crossfade(Duration p) {
    final id = track?.id;
    final fade = crossfade;
    if (id == null || fade <= Duration.zero || _handoff != null || !_engineOn || _startedFor != id) return;
    if (next == null || nextUrl.isEmpty || repeat == Repeat.one || source?.kind == 'album') return;
    final total = duration.value;
    if (total < fade * 3) return;
    final left = total - p;
    if (left > fade + _preloadAhead) return;
    if (left > fade) {
      engine.preload(nextUrl);
      return;
    }
    if (left < _shortestFade) return;
    _handoff = id;
    engine.crossfade(nextUrl, left);
    _send({'cmd': 'playerEnded', 'track': id, 'position': total.inMilliseconds / 1000});
  }

  static const _cutSlack = Duration(seconds: 5);

  double get _seconds => position.value.inMilliseconds / 1000;

  void _onCompleted() {
    final id = track?.id;
    if (id == null || _failedFor == id || _handoff == id) return;
    final total = duration.value;
    if (_startedFor == id && total > _cutSlack * 2 && position.value < total - _cutSlack) {
      _failedFor = id;
      _send({'cmd': 'playerError', 'track': id, 'message': 'поток оборвался', 'position': _seconds});
      return;
    }
    final played = duration.value > Duration.zero ? duration.value : position.value;
    _startedFor = null;
    _send({'cmd': 'playerEnded', 'track': id, 'position': played.inMilliseconds / 1000});
  }

  void _onError(String message) {
    final id = track?.id;
    if (id == null || _startedFor == id || _failedFor == id || _handoff == id) return;
    _failedFor = id;
    _send({'cmd': 'playerError', 'track': id, 'message': message, 'position': _seconds});
  }

  void Function(String message)? onBlocked;

  void Function(String link)? onShare;

  void share(String link) {
    if (link.isNotEmpty) onShare?.call(link);
  }

  void loadLyrics(PlayTrack t, {bool force = false}) {
    final known = lyrics[t.id];
    if (!force && known != null && known.status != LoadStatus.error) return;
    lyrics[t.id] = const Lyrics();
    _send({'cmd': 'lyrics', 'track': t.id});
    notifyListeners();
  }

  String get unavailable {
    final e = engine;
    return e is UnavailableEngine ? e.reason : '';
  }

  bool _blocked() {
    final reason = unavailable;
    if (reason.isEmpty) return false;
    onBlocked?.call(reason);
    return true;
  }

  void togglePlay() {
    if (_blocked()) return;
    if (track == null) {
      play(sourceWave);
      return;
    }
    if (_openPending()) return;
    if (playing) {
      pause();
    } else {
      engine.play();
    }
  }

  bool _openPending() {
    final at = _pending;
    final current = track;
    if (at == null || current == null) return false;
    _pending = null;
    _openedAt = at;
    engine.open(url, start: at, hint: current.duration);
    return true;
  }

  void resume() {
    if (track == null || playing || _blocked()) return;
    if (!_openPending()) engine.play();
  }

  void pause() {
    if (!playing) return;
    _userPaused = true;
    _settleAdvance();
    engine.pause();
  }

  void nextTrack() {
    final id = track?.id;
    if (id == null) return;
    _send({'cmd': 'playerNext', 'track': id, 'position': _seconds});
  }

  void previousTrack() {
    final id = track?.id;
    if (id == null) return;
    _send({'cmd': 'playerPrev', 'track': id, 'position': _seconds});
  }

  void seek(Duration to) {
    position.value = to;
    if (_pending != null) {
      _pending = to;
      return;
    }
    engine.seek(to);
    _reportPlayback();
  }

  void seekBy(Duration delta) {
    final max = duration.value;
    var to = position.value + delta;
    if (to < Duration.zero) to = Duration.zero;
    if (max > Duration.zero && to > max) to = max;
    seek(to);
  }

  void previewVolume(double v) {
    volume = v.clamp(0.0, 1.0);
    engine.setVolume(volume);
    notifyListeners();
  }

  void commitVolume() => _send({'cmd': 'playerVolume', 'volume': volume});

  double _beforeMute = 0.8;

  void toggleMute() {
    if (volume > 0) {
      _beforeMute = volume;
      previewVolume(0);
    } else {
      previewVolume(_beforeMute > 0 ? _beforeMute : 0.8);
    }
    commitVolume();
  }

  void cycleRepeat() {
    final options = wave ? const [Repeat.off, Repeat.one] : Repeat.values;
    final i = options.indexOf(repeat);
    _send({'cmd': 'playerRepeat', 'repeat': options[(i + 1) % options.length].name});
  }

  void toggleShuffle() => _send({'cmd': 'playerShuffle', 'on': !shuffle});

  void setQuality(PlayQuality q) => _send({'cmd': 'playerQuality', 'quality': q.name});

  void setAutoQuality() => _send({'cmd': 'playerQuality', 'quality': 'auto'});

  bool Function(List<Map<String, Object?>> commands)? divert;

  bool _diverted(List<Map<String, Object?>> commands) => divert?.call(commands) ?? false;

  void play(String source, {String? track, int index = 0}) {
    final command = {'cmd': 'play', 'source': source, 'track': ?track, 'index': index};
    if (_diverted([command]) || _blocked()) return;
    _send(command);
  }

  void playShuffled(String source) {
    final command = {'cmd': 'play', 'source': source, 'index': -1};
    if (_diverted([
      {'cmd': 'playerShuffle', 'on': true},
      command,
    ])) {
      return;
    }
    if (_blocked()) return;
    if (!shuffle) _send({'cmd': 'playerShuffle', 'on': true});
    _send(command);
  }

  void playWave({String source = '', PlayTrack? track, String title = ''}) {
    final command = {
      'cmd': 'wave',
      if (source.isNotEmpty) 'source': source,
      'track': ?track?.id,
      'title': title.isNotEmpty ? title : (track?.title ?? ''),
    };
    if (_diverted([command]) || _blocked()) return;
    _send(command);
  }

  void jump(int index) => _send({'cmd': 'playerJump', 'pos': index, 'position': _seconds});

  void like(PlayTrack t, bool on) => _send({'cmd': 'like', 'track': t.id, 'on': on});

  void dislike(PlayTrack t, bool on) => _send({'cmd': 'dislike', 'track': t.id, 'on': on, 'position': _seconds});

  void loadLibrary({bool force = false}) {
    if (!force && (library.status == LoadStatus.ok || library.status == LoadStatus.loading)) return;
    library = Library(status: LoadStatus.loading, likedCount: likedCount);
    _send({'cmd': 'library'});
    notifyListeners();
  }

  void loadHome({bool force = false}) {
    if (!force && (home.status == LoadStatus.ok || home.status == LoadStatus.loading)) return;
    home = const HomeFeed(status: LoadStatus.loading);
    _send({'cmd': 'home'});
    notifyListeners();
  }

  void openList(String source, {bool force = false}) {
    if (source == sourceHome) {
      loadHome(force: force);
      return;
    }
    final known = lists[source];
    if (!force && known != null && known.status != LoadStatus.error) {
      if (source == sourceHistory && known.status == LoadStatus.ok) _send({'cmd': 'open', 'source': source});
      return;
    }
    lists[source] = const TrackList();
    _send({'cmd': 'open', 'source': source});
    notifyListeners();
  }

  void requestQueue() => _send({'cmd': 'queue'});

  @override
  void dispose() {
    _bufferTimer?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    position.dispose();
    duration.dispose();
    panelOpen.dispose();
    lyricsOpen.dispose();
    browse.dispose();
    browsing.dispose();
    engine.dispose();
    super.dispose();
  }
}
