import 'dart:async';
import 'dart:math';

import 'package:media_kit/media_kit.dart';

abstract class AudioEngine {
  Stream<Duration> get position;
  Stream<Duration> get duration;
  Stream<bool> get playing;
  Stream<bool> get buffering;
  Stream<void> get completed;
  Stream<String> get errors;

  Future<void> open(String url, {Duration start = Duration.zero, bool play = true, Duration hint = Duration.zero});
  Future<void> preload(String url);
  Future<void> crossfade(String url, Duration length);
  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration to);
  Future<void> setVolume(double volume);
  Future<void> stop();
  Future<void> dispose();
}

enum _Fade { none, incoming, outgoing }

class MediaKitEngine implements AudioEngine {
  MediaKitEngine() : _main = _create(), _side = _create() {
    for (final p in [_main, _side]) {
      _subs.addAll([
        p.stream.position.listen((v) {
          if (p == _main) _position.add(v);
          if (_fade != _Fade.none && p == _incoming && v > Duration.zero) _startRamp();
        }),
        p.stream.duration.listen((v) => _forward(p, _duration, v)),
        p.stream.playing.listen((v) => _forward(p, _playing, v)),
        p.stream.buffering.listen((v) => _forward(p, _buffering, v)),
        p.stream.completed.where((done) => done).listen((_) => _forward(p, _completed, null)),
        p.stream.error.listen((v) {
          if (p == _side && _fade == _Fade.incoming) _sideError = v;
          _forward(p, _errors, v);
        }),
      ]);
    }
  }

  static Player _create() => Player(configuration: const PlayerConfiguration(title: 'YAMP'));

  static void init() => MediaKit.ensureInitialized();

  static const _tick = Duration(milliseconds: 40);

  Player _main;
  Player _side;
  String? _sideUrl;
  Future<void>? _loading;
  String? _sideError;
  var _fade = _Fade.none;
  var _gen = 0;
  var _length = Duration.zero;
  var _progress = 0.0;
  var _ramping = false;
  final _clock = Stopwatch();
  Timer? _ramp;
  var _volume = 1.0;

  final _subs = <StreamSubscription<Object?>>[];
  final _position = StreamController<Duration>.broadcast();
  final _duration = StreamController<Duration>.broadcast();
  final _playing = StreamController<bool>.broadcast();
  final _buffering = StreamController<bool>.broadcast();
  final _completed = StreamController<void>.broadcast();
  final _errors = StreamController<String>.broadcast();

  Player get _incoming => _fade == _Fade.incoming ? _side : _main;

  Player get _outgoing => _fade == _Fade.incoming ? _main : _side;

  void _forward<T>(Player p, StreamController<T> to, T v) {
    if (p == _main) to.add(v);
  }

  @override
  Stream<Duration> get position => _position.stream;

  @override
  Stream<Duration> get duration => _duration.stream;

  @override
  Stream<bool> get playing => _playing.stream;

  @override
  Stream<bool> get buffering => _buffering.stream;

  @override
  Stream<void> get completed => _completed.stream;

  @override
  Stream<String> get errors => _errors.stream;

  double _level(double amplitude) => (_volume * 100 * pow(amplitude, 1 / 3)).clamp(0, 100).toDouble();

  void _mix() {
    _outgoing.setVolume(_level(cos(_progress * pi / 2)));
    _incoming.setVolume(_level(sin(_progress * pi / 2)));
  }

  void _startRamp() {
    if (_ramping) return;
    _ramping = true;
    _clock
      ..reset()
      ..start();
    _ramp = Timer.periodic(_tick, (_) => _step());
    _step();
  }

  void _step() {
    final total = _length.inMicroseconds;
    _progress = total > 0 ? (_clock.elapsedMicroseconds / total).clamp(0.0, 1.0) : 1.0;
    _mix();
    if (_progress < 1) return;
    _ramp?.cancel();
    _ramp = null;
    _clock.stop();
    if (_fade == _Fade.outgoing) _settle();
  }

  void _settle() {
    if (_fade == _Fade.none) return;
    _gen++;
    _ramp?.cancel();
    _ramp = null;
    _clock.stop();
    _ramping = false;
    _progress = 0;
    _fade = _Fade.none;
    _sideUrl = null;
    _loading = null;
    _sideError = null;
    _side.stop();
    _main.setVolume(_level(1));
  }

  void _swap() {
    final old = _main;
    _main = _side;
    _side = old;
    _sideUrl = null;
    _loading = null;
    _fade = _Fade.outgoing;
    final s = _main.state;
    if (s.duration > Duration.zero) _duration.add(s.duration);
    _position.add(s.position);
    _buffering.add(s.buffering);
    if (s.playing) _playing.add(true);
    final error = _sideError;
    _sideError = null;
    if (error != null) _errors.add(error);
    if (_ramping && _progress >= 1) _settle();
  }

  Future<void> _load(String url) {
    _sideUrl = url;
    final p = _side;
    return _loading = p.setVolume(0).then((_) => p.open(Media(url), play: false));
  }

  @override
  Future<void> open(String url, {Duration start = Duration.zero, bool play = true, Duration hint = Duration.zero}) {
    if (_fade == _Fade.incoming && url == _sideUrl && start == Duration.zero && play) {
      _swap();
      return Future.value();
    }
    _settle();
    return _main.open(Media(url, start: start > Duration.zero ? start : null), play: play);
  }

  @override
  Future<void> preload(String url) async {
    if (_fade != _Fade.none || _sideUrl == url) return;
    await _load(url);
  }

  @override
  Future<void> crossfade(String url, Duration length) async {
    _settle();
    final gen = _gen;
    final p = _side;
    final loading = _sideUrl == url ? _loading : _load(url);
    _fade = _Fade.incoming;
    _length = length;
    _progress = 0;
    _ramping = false;
    await loading;
    if (gen != _gen) return;
    await p.play();
  }

  @override
  Future<void> play() => _main.play();

  @override
  Future<void> pause() {
    _settle();
    return _main.pause();
  }

  @override
  Future<void> seek(Duration to) {
    _settle();
    return _main.seek(to);
  }

  @override
  Future<void> setVolume(double volume) async {
    _volume = volume.clamp(0.0, 1.0);
    if (_fade == _Fade.none) {
      await _main.setVolume(_level(1));
    } else {
      _mix();
    }
  }

  @override
  Future<void> stop() async {
    _settle();
    _sideUrl = null;
    _loading = null;
    await _side.stop();
    await _main.stop();
  }

  @override
  Future<void> dispose() async {
    _ramp?.cancel();
    for (final s in _subs) {
      await s.cancel();
    }
    await _main.dispose();
    await _side.dispose();
  }
}

class SilentEngine implements AudioEngine {
  SilentEngine({this.tick});

  final Duration? tick;

  final _position = StreamController<Duration>.broadcast(sync: true);
  final _duration = StreamController<Duration>.broadcast(sync: true);
  final _playing = StreamController<bool>.broadcast(sync: true);
  final _buffering = StreamController<bool>.broadcast(sync: true);
  final _completed = StreamController<void>.broadcast(sync: true);
  final _errors = StreamController<String>.broadcast(sync: true);

  Timer? _timer;
  var _at = Duration.zero;
  var _length = Duration.zero;
  var _isPlaying = false;
  var volume = 1.0;
  String? url;
  String? preloaded;
  String? fadingTo;
  final fades = <(String, Duration)>[];
  var opens = 0;

  @override
  Stream<Duration> get position => _position.stream;

  @override
  Stream<Duration> get duration => _duration.stream;

  @override
  Stream<bool> get playing => _playing.stream;

  @override
  Stream<bool> get buffering => _buffering.stream;

  @override
  Stream<void> get completed => _completed.stream;

  @override
  Stream<String> get errors => _errors.stream;

  bool get isPlaying => _isPlaying;

  Duration get at => _at;

  void _setPlaying(bool v) {
    _isPlaying = v;
    _playing.add(v);
    _timer?.cancel();
    _timer = null;
    final t = tick;
    if (v && t != null) _timer = Timer.periodic(t, (_) => _advance(t));
  }

  void _advance(Duration by) {
    _at += by;
    if (_length > Duration.zero && _at >= _length) {
      _at = _length;
      _position.add(_at);
      finish();
      return;
    }
    _position.add(_at);
  }

  void finish() {
    _setPlaying(false);
    _completed.add(null);
  }

  void progress(Duration by) => _advance(by);

  void buffer(bool on) => _buffering.add(on);

  void fail(String message) {
    _setPlaying(false);
    _errors.add(message);
  }

  @override
  Future<void> open(
    String url, {
    Duration start = Duration.zero,
    bool play = true,
    Duration hint = Duration.zero,
  }) async {
    final swap = fadingTo == url && start == Duration.zero && play;
    fadingTo = null;
    if (!swap) opens++;
    this.url = url;
    _at = start;
    _length = hint;
    _duration.add(hint);
    _position.add(start);
    _setPlaying(play);
  }

  @override
  Future<void> preload(String url) async => preloaded = url;

  @override
  Future<void> crossfade(String url, Duration length) async {
    fadingTo = url;
    fades.add((url, length));
  }

  @override
  Future<void> play() async {
    if (url != null) _setPlaying(true);
  }

  @override
  Future<void> pause() async {
    fadingTo = null;
    _setPlaying(false);
  }

  @override
  Future<void> seek(Duration to) async {
    fadingTo = null;
    _at = to;
    _position.add(to);
  }

  @override
  Future<void> setVolume(double volume) async => this.volume = volume;

  @override
  Future<void> stop() async {
    url = null;
    fadingTo = null;
    _at = Duration.zero;
    _setPlaying(false);
    _position.add(Duration.zero);
  }

  @override
  Future<void> dispose() async {
    _timer?.cancel();
  }
}

class UnavailableEngine extends SilentEngine {
  UnavailableEngine(this.reason);

  final String reason;

  @override
  Future<void> open(String url, {Duration start = Duration.zero, bool play = true, Duration hint = Duration.zero}) =>
      super.open(url, start: start, play: false, hint: hint);

  @override
  Future<void> play() async {}
}
