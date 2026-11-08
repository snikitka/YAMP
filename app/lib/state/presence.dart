import 'player.dart';

class Presence {
  Presence(this.p, this._send) {
    p.addListener(_check);
    p.duration.addListener(_check);
    p.position.addListener(_seek);
  }

  static const _drift = Duration(seconds: 3);

  final PlayerState p;
  final void Function(Map<String, Object?>) _send;
  var _key = '';
  DateTime? _sentAt;
  var _sentPos = Duration.zero;

  Duration get _length {
    final d = p.duration.value;
    return d > Duration.zero ? d : (p.track?.duration ?? Duration.zero);
  }

  String get _state {
    final t = p.track;
    if (t == null || !p.playing) return '';
    return '${t.id}|${_length.inSeconds}';
  }

  void _check() {
    if (_state != _key) _push();
  }

  void _seek() {
    final at = _sentAt;
    if (at == null || _key.isEmpty) return;
    final expected = _sentPos + DateTime.now().difference(at);
    if ((p.position.value - expected).abs() > _drift) _push();
  }

  void _push() {
    _key = _state;
    final t = p.track;
    if (_key.isEmpty || t == null) {
      _sentAt = null;
      _send({'cmd': 'presence', 'playing': false});
      return;
    }
    _sentAt = DateTime.now();
    _sentPos = p.position.value;
    _send({
      'cmd': 'presence',
      'playing': true,
      'title': t.title,
      'artist': t.artists.isEmpty ? t.artist : t.artists.map((a) => a.name).join(', '),
      'album': t.album,
      'cover': t.cover.isNotEmpty ? t.cover : p.art,
      'link': t.link,
      'position': _sentPos.inMilliseconds / 1000,
      'duration': _length.inMilliseconds / 1000,
    });
  }

  void dispose() {
    p.removeListener(_check);
    p.duration.removeListener(_check);
    p.position.removeListener(_seek);
  }
}
